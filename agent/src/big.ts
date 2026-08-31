import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { HookInput, HookJSONOutput, Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import {
  composeBuildPrompt,
  composeGradePrompt,
  composeIntakeOpening,
  composeRebasePrompt,
  composeRevisionPrompt,
  composeTriagePrompt,
  INTAKE_SCHEMA,
  parseIntakeOutput,
  type GradeItem,
} from './bigprompts.js';
import {
  clearCapture,
  reconcile,
  transition,
  type BigBase,
  type BigSession,
  type BigSpec,
  type BigState,
  type BigStore,
  type Reality,
} from './bigstore.js';
import type { EmitEvent, SdkBindings } from './chat.js';
import { subscriptionEnv, type Env } from './env.js';
import {
  clears,
  gateArmed,
  GRADE_SCHEMA,
  parseGradeOutput,
  pendingFollowup,
  thresholdFor,
  type Difficulty,
  type GateGrade,
  type GateRound,
} from './gate.js';
import {
  abortRebase,
  captureDiff,
  cloneAt,
  fetchBase,
  readHead,
  rebaseCloneOnto,
  rebaseInProgress,
  removeClone,
  resolveRef,
} from './git.js';
import { branchNameFor, checkMerge, landDiff, type MergeFacts, type MergeRefusal } from './merge.js';
import { classifyBuildTool, READ_ONLY_TOOLS, realPathOf } from './policy.js';
import { ProtocolError } from './protocol.js';
import { readUsage, textDelta, toolCalls, type RunUsage } from './stream.js';
import {
  carryForward,
  countBlocks,
  fallbackBlocks,
  normalizeBlocks,
  parseTriageOutput,
  TRIAGE_SCHEMA,
  type RawBlock,
  type TriageBlock,
  type TriageCounts,
} from './triage.js';
import { parseUnifiedDiff, renderForTriage, type DiffHunk, type ParsedDiff, type RenderedTriage } from './unidiff.js';

/**
 * Big Change mode: interrogate the request into a spec, build it alone in a
 * disposable clone of the repo, then split the resulting diff into review
 * threads.
 *
 * Three agent turns, three different sets of powers, each set by SDK options
 * rather than by what the prompt asks for:
 *   * intake  — read-only, the same isolation chat runs under.
 *   * build   — free inside its clone, refused outside it.
 *   * triage  — read-only again, and reads only the diff it is handed.
 *
 * The record on disk is the source of truth for where a session is, and it is
 * reconciled against the filesystem on every read: a build the editor did not
 * live to see the end of comes back as "building, nobody driving", never as
 * "built". A lock file beside the record says whether that "nobody" is real,
 * because another Neovim on the same store may be the one driving it.
 */

/** Read-only, exactly as chat: intake and triage may look and nothing else. */
export const BIG_READ_TOOLS = [...READ_ONLY_TOOLS] as const;

/** The build's tool set. Explicit, so an SDK upgrade cannot widen it. */
export const BIG_BUILD_TOOLS = [...READ_ONLY_TOOLS, 'Edit', 'Write', 'Bash'] as const;

/** Auto-approved before `canUseTool` runs, so read-only only — never a write. */
export const BIG_AUTO_ALLOWED = [...READ_ONLY_TOOLS] as const;

/** Removed from every turn's context: delegation and slash commands. */
export const BIG_DENIED_TOOLS = ['Task', 'Agent', 'SlashCommand', 'NotebookEdit'] as const;

/** Additionally removed from the read-only turns: everything that mutates. */
export const BIG_READ_DENIED = [...BIG_DENIED_TOOLS, 'Bash', 'BashOutput', 'KillShell', 'Edit', 'Write'] as const;

/** How much of a diff the triage turn is shown. Past it, triage sees a prefix. */
export const MAX_TRIAGE_BYTES = 128 * 1024;

type Phase = 'intake' | 'build' | 'triage' | 'grade';

/** How much typed defense one thread accepts in one round. */
export const MAX_ANSWER_CHARS = 8000;

/** The most threads one grading round may cover. Past it, answer in batches. */
export const MAX_ANSWERS_PER_ROUND = 20;

export interface BigServiceOptions {
  sdk: Pick<SdkBindings, 'query'>;
  store: BigStore;
  claudePath: string;
  env: Env;
  emit: EmitEvent;
  model?: string | undefined;
}

/** What the picker lists: enough to choose, without the diff or the blocks. */
export interface SessionSummary {
  id: string;
  title: string;
  display: DisplayState;
  difficulty: Difficulty;
  detached: boolean;
  heldElsewhere: boolean;
  updatedAt: number;
  counts: TriageCounts;
}

/** `mergeable` is `reviewing` with nothing open — derived, never stored. */
export type DisplayState = BigState | 'mergeable';

export interface SessionView extends BigSession {
  display: DisplayState;
  detached: boolean;
  /** Another editor holds a live claim: read-only here, not ours to resume. */
  heldElsewhere: boolean;
  worktreeExists: boolean;
  hasDiff: boolean;
  counts: TriageCounts;
}

/** A hunk located in the captured diff: `text` line `offset`, `lineCount` long. */
export interface DiffHunkRef {
  id: string;
  file: string;
  offset: number;
  lineCount: number;
  /** Set only for a hunk nvime synthesized; there is no text to slice. */
  note?: string;
}

export interface CapturedDiff {
  text: string;
  hunks: DiffHunkRef[];
}

interface Run {
  requestId: number;
  key: string;
  abort: AbortController;
}

interface TurnResult {
  sessionId: string;
  text: string;
  structured: unknown;
  usage: RunUsage;
  costUsd: number;
}

export class BigService {
  readonly #sdk: Pick<SdkBindings, 'query'>;
  readonly #store: BigStore;
  readonly #claudePath: string;
  readonly #env: Env;
  readonly #emit: EmitEvent;
  readonly #model: string | undefined;
  readonly #running = new Map<number, Run>();
  readonly #runningByKey = new Map<string, number>();

  constructor(options: BigServiceOptions) {
    this.#sdk = options.sdk;
    this.#store = options.store;
    this.#claudePath = options.claudePath;
    this.#env = subscriptionEnv(options.env);
    this.#emit = options.emit;
    this.#model = options.model;
  }

  get activeRuns(): number {
    return this.#running.size;
  }

  create(root: string, title: string, difficulty: Difficulty): SessionView {
    return this.#view(this.#store.create(root, title, difficulty));
  }

  /**
   * Changes how hard the gate is. Only while the spec is still being drafted:
   * afterwards the threshold is what already-cleared threads were cleared at,
   * and moving it would silently re-rate a review that has already happened.
   */
  setDifficulty(root: string, id: string, difficulty: Difficulty): SessionView {
    const session = this.#store.require(root, id);
    if (session.state !== 'drafting') {
      throw new ProtocolError('bad_request', 'the difficulty is fixed once the spec is approved');
    }
    session.difficulty = difficulty;
    this.#store.save(session);
    return this.#view(session);
  }

  list(root: string): SessionSummary[] {
    return this.#store.list(root).map((session) => {
      const view = this.#view(session);
      return {
        id: view.id,
        title: view.title,
        display: view.display,
        difficulty: view.difficulty,
        detached: view.detached,
        heldElsewhere: view.heldElsewhere,
        updatedAt: view.updatedAt,
        counts: view.counts,
      };
    });
  }

  open(root: string, id: string): SessionView {
    return this.#view(this.#store.require(root, id));
  }

  /**
   * The captured diff for the thread view, with an index into it: the editor
   * slices the text by offset rather than being sent every hunk body twice.
   * Null before a capture, and null for a diff that is not the one this
   * session's threads describe.
   */
  diff(root: string, id: string): CapturedDiff | null {
    const text = this.#store.readVerifiedDiff(this.#store.require(root, id));
    if (text === null) return null;
    const hunks = parseUnifiedDiff(text).hunks.map((hunk) => ({
      id: hunk.id,
      file: hunk.file,
      offset: hunk.offset,
      lineCount: hunk.lineCount,
      ...(hunk.synthetic ? { note: hunk.lines[0] ?? 'changed' } : {}),
    }));
    return { text, hunks };
  }

  /** One intake exchange. The user's message, then the agent's next question. */
  async intake(requestId: number, params: { root: string; id: string; message: string }): Promise<SessionView> {
    const session = this.#store.require(params.root, params.id);
    if (session.state !== 'drafting') {
      throw new ProtocolError('bad_request', 'the spec for this big change is already approved');
    }
    session.conversation.push({ role: 'user', text: params.message, at: Date.now() });
    this.#store.save(session);

    const first = session.intakeSessionId === null;
    const prompt = first ? composeIntakeOpening(session.title, params.message) : params.message;
    const result = await this.#run(requestId, session, 'intake', () =>
      this.#turn(requestId, {
        prompt,
        cwd: session.repoRoot,
        phase: 'intake',
        resume: session.intakeSessionId,
        schema: INTAKE_SCHEMA,
      }),
    );

    session.intakeSessionId = result.sessionId;
    const answer = parseIntakeOutput(result.structured);
    // No usable structured answer: the prose is still a question worth showing,
    // but nothing here will invent a spec the user would then approve.
    const text = answer?.message ?? result.text;
    if (answer?.spec != null) session.spec = answer.spec;
    session.conversation.push({ role: 'agent', text, at: Date.now() });
    this.#store.save(session);
    return this.#view(session);
  }

  /**
   * Freezes the spec and records where the build will happen. Two `rev-parse`
   * reads and one record write — the clone itself is made by `build`, which
   * runs without a deadline, because a full checkout of a large repository is
   * exactly the case this feature exists for and would time the editor out.
   */
  async approve(root: string, id: string): Promise<SessionView> {
    const session = this.#store.require(root, id);
    if (session.state !== 'drafting') {
      throw new ProtocolError('bad_request', `this big change is already ${session.state}`);
    }
    if (session.spec === null) {
      throw new ProtocolError('bad_request', 'there is no spec to approve yet — keep answering the questions');
    }
    if (this.#store.hasWorktree(session)) {
      throw new ProtocolError('bad_request', 'this big change already has a build clone');
    }
    const head = await readHead(session.repoRoot);
    session.base = { commit: head.commit, branch: head.branch };
    session.worktree = {
      path: this.#store.worktreePathFor(session.repoRoot, session.id),
      createdAt: Date.now(),
      ready: false,
    };
    session.approvedAt = Date.now();
    transition(session, 'building', `base ${head.commit.slice(0, 8)}`);
    this.#store.save(session);
    return this.#view(session);
  }

  /**
   * Drives the build, then captures and triages what it produced. Called again
   * on a session whose build was cut short, it resumes the same SDK session in
   * the same clone rather than starting over on top of half a change.
   */
  async build(requestId: number, params: { root: string; id: string }): Promise<SessionView> {
    const session = this.#requireBuildable(params.root, params.id);
    const spec = session.spec;
    if (spec === null) throw new ProtocolError('bad_request', 'this big change has no approved spec');
    const worktree = session.worktree;
    if (worktree === null) throw new ProtocolError('bad_request', 'this big change has no build clone');
    const base = requireBase(session);

    if (session.state !== 'building') transition(session, 'building', 'rebuilding');
    this.#store.save(session);

    return this.#run(requestId, session, 'build', async () => {
      await this.#ensureClone(requestId, session, base);
      const resume = session.buildSessionId;
      const prompt =
        resume === null
          ? composeBuildPrompt(spec, worktree.path)
          : 'The previous run was interrupted. Check what is already in this working directory and finish the change.';
      const result = await this.#turn(requestId, {
        prompt,
        cwd: worktree.path,
        phase: 'build',
        resume,
        worktreeRoot: worktree.path,
      });
      session.buildSessionId = result.sessionId;
      session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session);
    });
  }

  /** Capture and triage on their own: the recovery path for a detached build. */
  async capture(requestId: number, params: { root: string; id: string }): Promise<SessionView> {
    const session = this.#requireBuildable(params.root, params.id);
    return this.#run(requestId, session, 'capture', () => this.#captureAndTriage(requestId, session));
  }

  /** The reviewer's `r`: send one block's comment back to the build agent. */
  async revise(
    requestId: number,
    params: { root: string; id: string; blockId: string; comment: string },
  ): Promise<SessionView> {
    const session = this.#store.require(params.root, params.id);
    this.#reconcileOrThrow(session);
    const worktree = session.worktree;
    if (worktree === null || !this.#store.hasWorktree(session)) {
      throw new ProtocolError('bad_request', 'this big change has no build clone to revise');
    }
    if (session.buildSessionId === null) {
      throw new ProtocolError('bad_request', 'nothing has been built yet to request changes on');
    }
    this.#refuseIfHeldElsewhere(session);
    const block = session.blocks.find((entry) => entry.id === params.blockId);
    if (block === undefined) throw new ProtocolError('bad_request', `no thread '${params.blockId}'`);

    transition(session, 'building', `requested changes on "${block.title}"`);
    session.conversation.push({ role: 'user', text: `[${block.title}] ${params.comment}`, at: Date.now() });
    this.#store.save(session);

    return this.#run(requestId, session, 'revise', async () => {
      const result = await this.#turn(requestId, {
        prompt: composeRevisionPrompt(block, params.comment),
        cwd: worktree.path,
        phase: 'build',
        resume: session.buildSessionId,
        worktreeRoot: worktree.path,
      });
      session.buildSessionId = result.sessionId;
      session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session);
    });
  }

  /**
   * The reviewer's `a`: defend one or more open threads, graded in ONE turn.
   *
   * Nothing here can clear a thread except a grade at or above the session's
   * threshold. A turn that fails, or answers unusably, records the answer with
   * no result and leaves the thread open — the reader is told why rather than
   * being handed a pass nobody gave them.
   */
  async answer(
    requestId: number,
    params: { root: string; id: string; answers: ReadonlyArray<{ blockId: string; text: string }> },
  ): Promise<SessionView> {
    const session = this.#store.require(params.root, params.id);
    this.#reconcileOrThrow(session);
    this.#refuseIfHeldElsewhere(session);
    const threshold = thresholdFor(session.difficulty);
    if (threshold === null) {
      throw new ProtocolError('bad_request', 'this change runs no gate — its difficulty is `vibe`');
    }
    if (session.state !== 'reviewing') {
      throw new ProtocolError('bad_request', `this big change is ${session.state}, not ready to defend`);
    }
    const diffText = this.#store.readVerifiedDiff(session);
    if (diffText === null) {
      throw new ProtocolError('bad_request', 'the captured diff is not the one these threads describe — re-triage it');
    }
    const answers = normalizeAnswers(params.answers);
    const items = buildGradeItems(session, answers, parseUnifiedDiff(diffText));

    return this.#run(requestId, session, 'grading', async () => {
      const grades = await this.#gradeRound(requestId, session, items, threshold);
      for (const item of items) {
        const block = session.blocks.find((entry) => entry.id === item.threadId);
        if (block === undefined) continue;
        block.rounds.push(roundFor(item.threadId, item.answer, grades));
        const grade = grades.kind === 'graded' ? grades.byThread.get(item.threadId) : undefined;
        if (grade !== undefined && clears(grade, threshold)) block.state = 'resolved';
      }
      this.#store.save(session);
      return this.#view(session);
    });
  }

  /**
   * One grading turn for the whole round. Read-only, in the build clone so the
   * grader can check a claim against the code, and resumed across rounds so a
   * follow-up remembers what it already asked.
   */
  async #gradeRound(
    requestId: number,
    session: BigSession,
    items: readonly GradeItem[],
    threshold: number,
  ): Promise<RoundGrades> {
    try {
      const result = await this.#turn(requestId, {
        prompt: composeGradePrompt(session.spec, threshold, items),
        cwd: session.worktree?.path ?? session.repoRoot,
        phase: 'grade',
        resume: session.gradeSessionId,
        schema: GRADE_SCHEMA,
      });
      session.gradeSessionId = result.sessionId;
      const byThread = parseGradeOutput(result.structured);
      if (byThread !== null) return { kind: 'graded', byThread };
      return this.#ungraded(requestId, 'the grading turn did not return grades');
    } catch (cause) {
      if (cause instanceof ProtocolError && cause.code === 'cancelled') throw cause;
      return this.#ungraded(requestId, cause instanceof Error ? cause.message : String(cause));
    }
  }

  #ungraded(requestId: number, reason: string): RoundGrades {
    this.#emit('big.notice', { id: requestId, text: `nothing was graded: ${reason}` });
    return { kind: 'ungraded', reason };
  }

  /** The reviewer's `X`: reopen an auto-resolved thread, or resolve it again. */
  toggleBlock(root: string, id: string, blockId: string, resolved: boolean): SessionView {
    const session = this.#store.require(root, id);
    const block = session.blocks.find((entry) => entry.id === blockId);
    if (block === undefined) throw new ProtocolError('bad_request', `no thread '${blockId}'`);
    if (block.substantial && resolved && gateArmed(session.difficulty)) {
      throw new ProtocolError('bad_request', 'a substantial thread is cleared by the review gate, not by hand');
    }
    if (session.state === 'merged') {
      throw new ProtocolError('bad_request', 'this change has already been merged');
    }
    block.state = resolved ? 'resolved' : 'open';
    block.reopened = !resolved;
    this.#store.save(session);
    return this.#view(session);
  }

  /**
   * What stands between this change and the operator's branch, right now.
   * Reads only — the editor draws the gate line from it, and `merge` recomputes
   * the same thing rather than trusting whatever this last returned.
   */
  async mergeCheck(root: string, id: string): Promise<{ session: SessionView; refusals: MergeRefusal[] }> {
    const session = this.#store.require(root, id);
    const view = this.#view(session);
    return { session: view, refusals: await checkMerge(session, this.#mergeFacts(session, view.counts)) };
  }

  /**
   * `M`: land the reviewed diff on the base branch, locally.
   *
   * The one write nvime makes to the operator's repository. Every precondition
   * is re-asserted here, under the run lock, whatever the editor believed; a
   * refusal is an ANSWER (the reasons, listed) rather than an exception, so the
   * editor can offer the rebase when the base has moved.
   */
  async merge(
    requestId: number,
    params: { root: string; id: string; cleanup?: boolean },
  ): Promise<{ session: SessionView; merged: boolean; refusals: MergeRefusal[] }> {
    const session = this.#store.require(params.root, params.id);
    this.#reconcileOrThrow(session);
    this.#refuseIfHeldElsewhere(session);

    return this.#run(requestId, session, 'merging', async () => {
      // Inside the lock: the check the merge is actually made on. Nothing the
      // editor asked with, and nothing computed before the claim was held.
      const refusals = await checkMerge(session, this.#mergeFacts(session, countBlocks(session.blocks)));
      if (refusals.length > 0) return { session: this.#view(session), merged: false, refusals };

      const base = requireBase(session);
      if (base.branch === null) throw new ProtocolError('internal', 'checkMerge passed a change with no base branch');
      const branch = await this.#freeBranchName(session);
      this.#emit('big.state', { id: requestId, session: session.id, state: 'reviewing', note: `landing on ${branch}` });
      const landed = await landDiff({
        repoRoot: session.repoRoot,
        branch,
        baseBranch: base.branch,
        baseCommit: base.commit,
        patchPath: this.#store.diffPathFor(session.repoRoot, session.id),
        message: session.title,
        indexFile: join(this.#store.dirFor(session.repoRoot, session.id), 'merge-index'),
      });

      session.merge = { branch: landed.branch, commit: landed.commit, baseBranch: base.branch, at: Date.now() };
      transition(session, 'merged', `${landed.commit.slice(0, 8)} on ${base.branch}`);
      this.#store.save(session);
      if (params.cleanup === true) await this.#cleanupClone(session);
      return { session: this.#view(session), merged: true, refusals: [] };
    });
  }

  /**
   * Moves the build onto a base branch that has advanced since it started, then
   * re-captures and re-triages. Content the reader already cleared carries
   * forward by signature; anything the move changed comes back open.
   */
  async rebase(requestId: number, params: { root: string; id: string }): Promise<SessionView> {
    const session = this.#requireBuildable(params.root, params.id);
    const base = requireBase(session);
    const worktree = session.worktree;
    if (base.branch === null || worktree === null) {
      throw new ProtocolError('bad_request', 'this change has no base branch to rebase onto');
    }
    const head = await resolveRef(session.repoRoot, base.branch);
    if (head === null) throw new ProtocolError('bad_request', `${base.branch} no longer exists`);
    if (head === base.commit) throw new ProtocolError('bad_request', `${base.branch} has not moved`);

    return this.#run(requestId, session, 'rebasing', async () => {
      const fetched = await fetchBase(worktree.path, session.repoRoot, base.branch as string);
      const { conflicted } = await rebaseCloneOnto(worktree.path, fetched);
      this.#emit('big.state', {
        id: requestId,
        session: session.id,
        state: 'building',
        note: conflicted ? 'the rebase hit conflicts — resolving them' : 're-verifying on the new base',
      });
      await this.#finishRebase(requestId, session, worktree.path, conflicted, base.branch as string);
      session.base = { commit: fetched, branch: base.branch };
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session);
    });
  }

  /**
   * The half of a rebase only a reader of the code can do: resolving conflicts
   * and fixing what the new base broke. A rebase the agent could not finish is
   * ABORTED rather than left half-applied — a clone stopped mid-rebase has no
   * diff to capture, and the old base is a state the reader can still act on.
   */
  async #finishRebase(
    requestId: number,
    session: BigSession,
    clonePath: string,
    conflicted: boolean,
    baseBranch: string,
  ): Promise<void> {
    const result = await this.#turn(requestId, {
      prompt: composeRebasePrompt(conflicted, baseBranch),
      cwd: clonePath,
      phase: 'build',
      resume: session.buildSessionId,
      worktreeRoot: clonePath,
    });
    session.buildSessionId = result.sessionId;
    session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
    if (!(await rebaseInProgress(clonePath))) return;
    await abortRebase(clonePath);
    throw new ProtocolError(
      'agent_error',
      'the rebase could not be finished, so it was undone',
      `the build clone is back on ${baseBranch} as it was; the change still reviews against its old base`,
    );
  }

  /** A branch name nothing already holds, so landing cannot clobber a ref. */
  async #freeBranchName(session: BigSession): Promise<string> {
    const preferred = branchNameFor(session.title, session.id);
    for (const candidate of [preferred, `${preferred}-${session.id}`]) {
      if ((await resolveRef(session.repoRoot, `refs/heads/${candidate}`)) === null) return candidate;
    }
    throw new ProtocolError('bad_request', `${preferred} already exists — delete or rename it first`);
  }

  /** Drops the build clone once the change has landed and nobody needs it. */
  async #cleanupClone(session: BigSession): Promise<void> {
    if (session.worktree === null) return;
    await this.#guardedRemoveClone(session, session.worktree.path);
    session.worktree = null;
    session.buildSessionId = null;
    this.#store.save(session);
  }

  #mergeFacts(session: BigSession, counts: TriageCounts): MergeFacts {
    const text = this.#store.readVerifiedDiff(session);
    return {
      diff: text === null ? null : parseUnifiedDiff(text),
      counts,
      heldElsewhere: this.#store.foreignLock(session) !== null,
    };
  }

  /** Throws away the clone and the record. Only ever on an explicit ask. */
  async discard(root: string, id: string): Promise<{ discarded: boolean }> {
    const session = this.#store.require(root, id);
    if (this.#runningByKey.has(keyOf(session))) {
      throw new ProtocolError('busy', 'this big change is still running — stop it first');
    }
    // A discard from here would pull the clone out from under another editor's
    // live build, which dies with an opaque git failure and then re-saves the
    // record this just destroyed.
    const held = this.#store.foreignLock(session);
    if (held !== null) {
      throw new ProtocolError('busy', `this big change is running in another editor (${held.what}) — stop it there`);
    }
    if (session.worktree !== null) await this.#guardedRemoveClone(session, session.worktree.path);
    this.#store.destroy(root, id);
    return { discarded: true };
  }

  cancel(requestId: number): boolean {
    const run = this.#running.get(requestId);
    if (run === undefined) return false;
    run.abort.abort();
    return true;
  }

  // ---- internals ----------------------------------------------------------

  #requireBuildable(root: string, id: string): BigSession {
    const session = this.#store.require(root, id);
    // Reconcile first: a clone that vanished is already back at `drafting` by
    // the time this looks, so the check below is about approval, not disk.
    this.#reconcileOrThrow(session);
    if (session.state === 'drafting') {
      throw new ProtocolError('bad_request', 'approve the spec before building');
    }
    if (session.worktree === null) {
      throw new ProtocolError('bad_request', 'the build clone is gone — approve again to rebuild');
    }
    this.#refuseIfHeldElsewhere(session);
    return session;
  }

  /**
   * Refuses before the caller writes anything. `#run` would refuse too, but
   * only after a transition and a save have already landed on a record another
   * editor is actively working.
   */
  #refuseIfHeldElsewhere(session: BigSession): void {
    const held = this.#store.foreignLock(session);
    if (held !== null) {
      throw new ProtocolError('busy', `this big change is running in another editor (${held.what})`);
    }
  }

  /**
   * Makes the build's clone if it is not there yet. Off `approve`'s request
   * path on purpose: this is a full checkout, and it is bounded by the git
   * timeout rather than by the editor's control deadline.
   */
  async #ensureClone(requestId: number, session: BigSession, base: BigBase): Promise<void> {
    const worktree = session.worktree;
    if (worktree === null) throw new ProtocolError('bad_request', 'this big change has no build clone');
    if (worktree.ready && this.#store.hasWorktree(session)) return;
    this.#emit('big.state', {
      id: requestId,
      session: session.id,
      state: 'building',
      note: 'cloning the repo at the approved commit',
    });
    // A half-made clone from an interrupted approval would fail `git clone`
    // on a non-empty destination; there is nothing in it worth keeping.
    await this.#guardedRemoveClone(session, worktree.path);
    mkdirSync(dirname(worktree.path), { recursive: true });
    await cloneAt(session.repoRoot, worktree.path, base.commit);
    worktree.ready = true;
    this.#store.save(session);
  }

  /**
   * `removeClone` is an unbounded `rm -rf`, and `dir` here is a path read back
   * out of `session.json` — the store validates the session id for exactly
   * this reason, and a path field must be held to the same standard. Refuses
   * rather than silently skipping, so a tampered record surfaces as a failure
   * instead of a build that quietly proceeds against who-knows-what directory.
   */
  async #guardedRemoveClone(session: BigSession, dir: string): Promise<void> {
    const expected = this.#store.worktreePathFor(session.repoRoot, session.id);
    if (dir !== expected) {
      throw new ProtocolError(
        'agent_error',
        'refusing to remove a clone path this session does not own',
        `expected ${expected}, got ${dir}`,
      );
    }
    await removeClone(dir);
  }

  /** Applies the disk's version of events to the record before acting on it. */
  #reconcileOrThrow(session: BigSession): void {
    const result = reconcile(session, this.#realityOf(session));
    if (result.changed) this.#store.save(session);
  }

  #realityOf(session: BigSession): Reality {
    return {
      worktreeExists: this.#store.hasWorktree(session),
      diffExists: this.#store.hasDiff(session),
      diffVerified: this.#store.readVerifiedDiff(session) !== null,
      running: this.#runningByKey.has(keyOf(session)),
      // The store is shared by every open Neovim, so "nobody is driving this"
      // is a claim about the machine, not about this process.
      heldElsewhere: this.#store.foreignLock(session) !== null,
    };
  }

  /**
   * Captures the clone's diff and splits it into threads. A triage turn that
   * fails or answers unusably falls back to one block per file — the hunks are
   * never dropped, and the reason is put on screen and into the fallback's own
   * rationale rather than swallowed.
   *
   * The capture is disowned before it is taken and re-owned together with the
   * blocks in one record write. Anything that goes wrong in between therefore
   * leaves a `triaging` session with NO threads and no reviewable diff, which
   * is re-triaged; it can never leave one build's threads over another
   * build's hunks, which would show a reviewer content nobody sorted and hide
   * content that was.
   */
  async #captureAndTriage(requestId: number, session: BigSession): Promise<SessionView> {
    const worktree = session.worktree;
    if (worktree === null || !worktree.ready) {
      throw new ProtocolError('bad_request', 'this big change has nothing built to capture');
    }
    const base = requireBase(session);
    const previous = session.blocks;
    clearCapture(session);
    transition(session, 'triaging', 'capturing the diff');
    this.#emit('big.state', { id: requestId, session: session.id, state: 'triaging' });
    this.#store.save(session);

    const text = await captureDiff(worktree.path, base.commit);
    const diffId = this.#store.stageDiff(session, text);
    const bytes = Buffer.byteLength(text, 'utf8');
    const parsed = parseUnifiedDiff(text);

    if (parsed.hunks.length === 0) {
      transition(session, 'reviewing', 'the build changed nothing');
      this.#store.commitCapture(session, { id: diffId, bytes, blocks: [] });
      return this.#view(session);
    }

    const rendered = renderForTriage(parsed, MAX_TRIAGE_BYTES);
    if (rendered.truncated) {
      const hidden = parsed.hunks.length - rendered.shownIds.size;
      this.#emit('big.notice', {
        id: requestId,
        text: `${hidden} hunk(s) exceeded the triage window and were not shown`,
      });
    }
    const unshownIds = new Set(parsed.hunks.filter((hunk) => !rendered.shownIds.has(hunk.id)).map((hunk) => hunk.id));
    const raw = await this.#triageBlocks(requestId, session, parsed, rendered);
    const armed = gateArmed(session.difficulty);
    const blocks = carryForward(previous, normalizeBlocks(raw, parsed, unshownIds, armed));
    transition(session, 'reviewing', `${blocks.length} thread(s) from ${parsed.hunks.length} hunk(s)`);
    this.#store.commitCapture(session, { id: diffId, bytes, blocks });
    return this.#view(session);
  }

  async #triageBlocks(
    requestId: number,
    session: BigSession,
    parsed: ParsedDiff,
    rendered: RenderedTriage,
  ): Promise<RawBlock[]> {
    const worktree = session.worktree;
    let reason: string;
    try {
      const result = await this.#turn(requestId, {
        prompt: composeTriagePrompt(
          session.spec,
          rendered.text,
          rendered.truncated,
          rendered.shownIds.size,
          rendered.totalHunks,
        ),
        cwd: worktree?.path ?? session.repoRoot,
        phase: 'triage',
        resume: null,
        schema: TRIAGE_SCHEMA,
      });
      const blocks = parseTriageOutput(result.structured);
      if (blocks !== null) return blocks;
      reason = 'the triage turn did not return a grouping';
    } catch (cause) {
      if (cause instanceof ProtocolError && cause.code === 'cancelled') throw cause;
      reason = cause instanceof Error ? cause.message : String(cause);
    }
    this.#emit('big.notice', { id: requestId, text: `triage fell back to one thread per file: ${reason}` });
    return fallbackBlocks(parsed).map((block) => ({ ...block, rationale: `${block.rationale} (${reason})` }));
  }

  /**
   * Runs `body` as the session's one live operation. Registering the run is
   * what makes `reconcile` able to tell "building" from "building, and nobody
   * is driving it", so nothing that drives an agent may skip it.
   */
  async #run<T>(requestId: number, session: BigSession, what: string, body: () => Promise<T>): Promise<T> {
    const key = keyOf(session);
    if (this.#runningByKey.has(key)) {
      throw new ProtocolError('busy', `this big change is already running (${what})`);
    }
    // On disk as well as in memory: the in-process map cannot see the second
    // Neovim, which shares this store and would otherwise build in the same
    // clone and discard the session out from under this run.
    const lock = this.#store.acquireLock(session, what);
    const run: Run = { requestId, key, abort: new AbortController() };
    this.#running.set(requestId, run);
    this.#runningByKey.set(key, requestId);
    try {
      return await body();
    } catch (cause) {
      throw translate(cause, run.abort);
    } finally {
      this.#running.delete(requestId);
      this.#runningByKey.delete(key);
      lock.release();
    }
  }

  /** One agent turn, streamed into the panel and reduced to its result. */
  async #turn(
    requestId: number,
    spec: {
      prompt: string;
      cwd: string;
      phase: Phase;
      resume: string | null;
      schema?: Record<string, unknown>;
      worktreeRoot?: string;
    },
  ): Promise<TurnResult> {
    const abort = this.#abortFor(requestId);
    const options = this.#buildOptions(requestId, spec, abort);
    let sessionId = spec.resume ?? '';

    for await (const message of this.#sdk.query({ prompt: spec.prompt, options })) {
      if (message.type === 'system' && message.subtype === 'init') {
        sessionId = message.session_id;
        this.#emit('big.started', { id: requestId, phase: spec.phase, sessionId, model: message.model });
      } else if (message.type === 'stream_event') {
        const delta = textDelta(message.event);
        if (delta !== null) this.#emit('big.delta', { id: requestId, text: delta });
      } else if (message.type === 'assistant') {
        if (message.error === 'authentication_failed') {
          throw new ProtocolError(
            'not_logged_in',
            'claude is installed but not logged in — run `claude` in a terminal and sign in',
          );
        }
        for (const call of toolCalls(message.message, spec.cwd)) {
          this.#emit('big.tool', { id: requestId, tool: call.tool, summary: call.summary });
        }
      } else if (message.type === 'result') {
        if (message.subtype !== 'success' || message.is_error) {
          const detail = message.subtype === 'success' ? message.result : message.errors.join('; ');
          throw new ProtocolError('agent_error', `the ${spec.phase} turn failed (${message.subtype})`, detail);
        }
        return {
          sessionId: sessionId === '' ? message.session_id : sessionId,
          text: message.result,
          structured: message.structured_output,
          usage: readUsage(message.usage),
          costUsd: message.total_cost_usd,
        };
      }
    }
    throw new ProtocolError('agent_error', `the ${spec.phase} turn ended without a result`);
  }

  #abortFor(requestId: number): AbortController {
    const run = this.#running.get(requestId);
    if (run === undefined) throw new Error(`no live big-change run ${requestId}`);
    return run.abort;
  }

  #buildOptions(
    requestId: number,
    spec: { cwd: string; phase: Phase; resume: string | null; schema?: Record<string, unknown>; worktreeRoot?: string },
    abort: AbortController,
  ): Options {
    const build = spec.phase === 'build';
    const realWorktree = buildWriteBoundary(build, spec.worktreeRoot);
    return {
      cwd: spec.cwd,
      // A copy per turn: the SDK mutates the env object it is handed.
      env: { ...this.#env },
      pathToClaudeCodeExecutable: this.#claudePath,
      abortController: abort,
      includePartialMessages: true,
      // `default` routes every non-auto-allowed tool through `canUseTool`;
      // read-only turns have nothing to route, so they never prompt either.
      permissionMode: build ? 'default' : 'dontAsk',
      tools: build ? [...BIG_BUILD_TOOLS] : [...BIG_READ_TOOLS],
      allowedTools: [...BIG_AUTO_ALLOWED],
      disallowedTools: build ? [...BIG_DENIED_TOOLS] : [...BIG_READ_DENIED],
      // Same reasoning as chat and edit: `'project'` would load the repo's own
      // .claude/settings.json, whose hooks run shell commands and whose
      // apiKeyHelper/env re-add the credentials env.ts stripped.
      settingSources: [],
      ...(realWorktree === null
        ? {}
        : {
            canUseTool: async (toolName, input) => this.#canUseTool(requestId, toolName, input, realWorktree),
            // The callback is not enough on its own: in `default` mode the CLI
            // approves some calls without ever asking it. This hook runs first
            // and refuses out-of-worktree writes before that can happen.
            hooks: { PreToolUse: [{ hooks: [(input) => this.#preToolUse(input, realWorktree)] }] },
          }),
      ...(spec.schema === undefined ? {} : { outputFormat: { type: 'json_schema', schema: spec.schema } }),
      ...(spec.resume === null ? {} : { resume: spec.resume }),
      ...(this.#model === undefined ? {} : { model: this.#model }),
    };
  }

  async #preToolUse(input: HookInput, realWorktree: string): Promise<HookJSONOutput> {
    if (input.hook_event_name !== 'PreToolUse') return { continue: true };
    const toolInput = (input.tool_input ?? {}) as Record<string, unknown>;
    const decision = classifyBuildTool(input.tool_name, toolInput, realWorktree);
    if (decision.kind === 'allow') return { continue: true };
    return {
      continue: true,
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: decision.reason,
      },
    };
  }

  /**
   * The build's enforcement point. Nothing here asks: a build outlives the
   * editor, so a prompt could be raised with nobody to answer it, and the
   * fail-safe answer when no one is watching is no.
   */
  async #canUseTool(
    requestId: number,
    toolName: string,
    input: Record<string, unknown>,
    realWorktree: string,
  ): Promise<{ behavior: 'allow' } | { behavior: 'deny'; message: string }> {
    const decision = classifyBuildTool(toolName, input, realWorktree);
    if (decision.kind === 'allow') return { behavior: 'allow' };
    this.#emit('big.denied', { id: requestId, tool: toolName, reason: decision.reason });
    return { behavior: 'deny', message: decision.reason };
  }

  #view(session: BigSession): SessionView {
    const result = reconcile(session, this.#realityOf(session));
    if (result.changed) this.#store.save(session);
    const counts = countBlocks(session.blocks);
    const mergeable = session.state === 'reviewing' && counts.open === 0 && counts.total > 0;
    return {
      ...session,
      display: mergeable ? 'mergeable' : session.state,
      detached: result.detached,
      heldElsewhere: result.heldElsewhere,
      worktreeExists: this.#store.hasWorktree(session),
      hasDiff: this.#store.hasDiff(session),
      counts,
    };
  }
}

/**
 * The build's write boundary: the real path `canUseTool` and the `PreToolUse`
 * hook confine every write to, or `null` for a read-only turn that installs
 * neither. A build turn with no `worktreeRoot` is a caller's bug, not a
 * reason to run with mutation tools and no gate — it must fail closed.
 */
export function buildWriteBoundary(build: boolean, worktreeRoot: string | undefined): string | null {
  if (!build) return null;
  if (worktreeRoot === undefined) {
    throw new Error('a build turn requires worktreeRoot to install its write boundary');
  }
  return realPathOf(worktreeRoot);
}

function keyOf(session: BigSession): string {
  return `${session.repoRoot} ${session.id}`;
}

/**
 * The commit the change is built on. Absent only for a record that never got
 * past drafting, so every caller that has a build has one.
 */
function requireBase(session: BigSession): BigBase {
  const base = session.base;
  if (base === null) throw new ProtocolError('bad_request', 'this big change has no recorded base commit');
  return base;
}

/** The grading turn's answer for a whole round, or why there isn't one. */
type RoundGrades =
  | { kind: 'graded'; byThread: ReadonlyMap<string, GateGrade> }
  | { kind: 'ungraded'; reason: string };

/** One thread's round: the grade it got, or the honest reason it has none. */
function roundFor(threadId: string, answer: string, grades: RoundGrades): GateRound {
  const at = Date.now();
  if (grades.kind === 'ungraded') return { at, answer, result: null, ungraded: grades.reason };
  const grade = grades.byThread.get(threadId);
  if (grade === undefined) {
    return { at, answer, result: null, ungraded: 'the grading turn returned no verdict for this thread' };
  }
  return { at, answer, result: grade };
}

/** The round the editor sent, validated at the boundary before anything runs. */
function normalizeAnswers(
  raw: ReadonlyArray<{ blockId: string; text: string }>,
): Array<{ blockId: string; text: string }> {
  if (raw.length === 0) throw new ProtocolError('bad_request', 'there is nothing to grade');
  if (raw.length > MAX_ANSWERS_PER_ROUND) {
    throw new ProtocolError('bad_request', `at most ${MAX_ANSWERS_PER_ROUND} threads can be graded in one round`);
  }
  const seen = new Set<string>();
  return raw.map((entry) => {
    const text = entry.text.trim();
    if (text === '') throw new ProtocolError('bad_request', `the answer for '${entry.blockId}' is empty`);
    if (text.length > MAX_ANSWER_CHARS) {
      throw new ProtocolError('bad_request', `an answer may be at most ${MAX_ANSWER_CHARS} characters`);
    }
    if (seen.has(entry.blockId)) throw new ProtocolError('bad_request', `'${entry.blockId}' was answered twice`);
    seen.add(entry.blockId);
    return { blockId: entry.blockId, text };
  });
}

/**
 * What the grader is shown for each answered thread: the hunks the reader read,
 * the rounds already spent on it, and the follow-up this answer had to address.
 *
 * Refuses a thread that is not open substance — a cleared thread has nothing
 * left to defend, and grading trivia would let the loop be padded with it.
 */
function buildGradeItems(
  session: BigSession,
  answers: ReadonlyArray<{ blockId: string; text: string }>,
  parsed: ParsedDiff,
): GradeItem[] {
  const hunks = new Map(parsed.hunks.map((hunk) => [hunk.id, hunk]));
  return answers.map((entry) => {
    const block = session.blocks.find((candidate) => candidate.id === entry.blockId);
    if (block === undefined) throw new ProtocolError('bad_request', `no thread '${entry.blockId}'`);
    if (block.state !== 'open') throw new ProtocolError('bad_request', `'${block.title}' is already cleared`);
    if (!block.substantial) throw new ProtocolError('bad_request', `'${block.title}' is trivia — it needs no defense`);
    return {
      threadId: block.id,
      title: block.title,
      rationale: block.rationale,
      diff: renderBlockDiff(block, hunks),
      history: block.rounds,
      followup: pendingFollowup(block.rounds) ?? '',
      answer: entry.text,
    };
  });
}

/** A thread's hunks, exactly as the reviewer read them in the pane. */
function renderBlockDiff(block: TriageBlock, hunks: ReadonlyMap<string, DiffHunk>): string {
  const parts: string[] = [];
  for (const id of block.hunkIds) {
    const hunk = hunks.get(id);
    if (hunk === undefined) continue;
    parts.push(`--- ${hunk.file}\n${hunk.header}\n${hunk.lines.join('\n')}`);
  }
  if (parts.length === 0) {
    // The blocks and the diff are written in one record write, so this means a
    // bug here rather than an ordinary state — never a thread graded on nothing.
    throw new ProtocolError('internal', `thread '${block.id}' names no hunk in the captured diff`);
  }
  return parts.join('\n');
}

function translate(cause: unknown, abort: AbortController): ProtocolError {
  if (cause instanceof ProtocolError) return cause;
  if (abort.signal.aborted) return new ProtocolError('cancelled', 'the big change was stopped');
  const message = cause instanceof Error ? cause.message : String(cause);
  if (/not found|ENOENT|failed to launch/i.test(message)) {
    return new ProtocolError('claude_not_found', 'could not launch the claude CLI', message);
  }
  return new ProtocolError('agent_error', 'the big-change run failed', message);
}

export type { BigSpec, TriageBlock };
