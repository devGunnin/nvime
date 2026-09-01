import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type {
  EffortLevel,
  HookInput,
  HookJSONOutput,
  Options,
  SDKMessage,
  SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import {
  composeBuildPrompt,
  composeExplainPrompt,
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
  type BigRunner,
  type BigSession,
  type BigSpec,
  type BigState,
  type BigStore,
  type Reality,
  type SessionLock,
} from './bigstore.js';
import type { EmitEvent } from './chat.js';
import { dialOptions, type Dial } from './dial.js';
import { stripGateEnv, subscriptionEnv, type Env } from './env.js';
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
import {
  branchCandidates,
  branchNameFor,
  checkMerge,
  expectedTree,
  landDiff,
  landedAlready,
  type LandResult,
  type MergeFacts,
  type MergeRefusal,
} from './merge.js';
import { classifyBuildTool, READ_ONLY_TOOLS, realPathOf } from './policy.js';
import { ProtocolError } from './protocol.js';
import { steeredPrompt, type SteerControl } from './steer.js';
import { readUsage, textDelta, toolCalls, type RunUsage } from './stream.js';
import {
  carryForward,
  countBlocks,
  fallbackBlocks,
  normalizeBlocks,
  parseTriageOutput,
  TRIAGE_SCHEMA,
  withTrivialAck,
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
 *
 * This service does not decide WHERE it runs. In the sidecar it is one editor's
 * build; in the detached runner (`runner.ts`) it is the same code with a steer
 * queue and a runner identity handed in, driving a build that outlives the
 * editor. Both go through the same turns, the same write boundary and the same
 * gate floors — the only difference is who is watching.
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

/**
 * How long a steered turn waits for the steer's own turn to start before it
 * decides the build is over. Comfortably above the ~1s the CLI takes to answer
 * a queued message, and paid once, at the end of a steered build.
 */
export const STEER_SETTLE_MS = 10_000;

/** Why a steer is refused once its build turn has stopped reading input. */
export const STEER_CLOSED = 'the build agent has stopped taking input — start a revision instead';

export type Phase = 'intake' | 'build' | 'triage' | 'grade' | 'explain';

/** The phases whose output the comprehension gate depends on: never effort 'low'. */
const GATE_PHASES: ReadonlySet<Phase> = new Set(['triage', 'grade']);

/** The floor a gate phase's effort defaults to when its own dial leaves it unset. */
const GATE_EFFORT_FLOOR: EffortLevel = 'medium';

/**
 * A gate phase's effort can never be below the floor — a CLAMP, not a
 * default: an explicit `'low'` is raised to the floor exactly like an unset
 * one, regardless of whatever call-site guard did or didn't check first.
 * `#buildOptions` is the single place every turn's options are assembled, so
 * this is the one function that must hold the invariant; the call-site
 * refusals (`refuseLowTriage`, `answer`'s effort check) stay only for the
 * user-facing error message, not as the enforcement itself.
 */
export function gateDial(phase: Phase, dial: Dial): Dial {
  if (!GATE_PHASES.has(phase)) return dial;
  const effort = dial.effort === undefined || dial.effort === 'low' ? GATE_EFFORT_FLOOR : dial.effort;
  return { model: dial.model, effort };
}

/**
 * A build/capture/revise/rebase call's own dial, plus the triage lane's on
 * top: every call that captures and triages a build carries both. The triage
 * half is optional here only because the wire format allows omitting it —
 * `#captureAndTriage` still resolves a concrete triage dial for every call.
 */
export interface BuildDial extends Dial {
  triageModel?: string | undefined;
  triageEffort?: EffortLevel | undefined;
}

/** How much typed defense one thread accepts in one round. */
export const MAX_ANSWER_CHARS = 8000;

/** The most threads one grading round may cover. Past it, answer in batches. */
export const MAX_ANSWERS_PER_ROUND = 20;

/**
 * The SDK surface big-change mode needs. Wider than chat's on one axis only:
 * a build turn may be driven by a stream of user messages rather than a single
 * prompt string, which is what makes steering a running build possible.
 */
export interface BigSdk {
  query: (params: {
    prompt: string | AsyncIterable<SDKUserMessage>;
    options?: Options;
  }) => AsyncIterable<SDKMessage>;
}

export interface BigServiceOptions {
  sdk: BigSdk;
  store: BigStore;
  claudePath: string;
  env: Env;
  emit: EmitEvent;
  /**
   * Set only in the detached runner: the queue a running build reads steers
   * from, and the identity it records on the session while it holds the claim.
   * Absent in the sidecar, where a build is editor-scoped and unsteerable.
   */
  steering?: SteerControl | undefined;
  runner?: BigRunner | undefined;
  /**
   * The session's claim, already taken by the process that built this service.
   * The runner takes it before it opens the event log, so a runner that loses
   * the race exits without writing a byte — and then this must not take it a
   * second time, nor drop it when the run ends.
   */
  heldLock?: SessionLock | undefined;
  /** Overrides `STEER_SETTLE_MS`; only a test has a reason to shorten it. */
  steerSettleMs?: number | undefined;
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
  /**
   * The recorded detached runner is really behind the claim. Distinct from
   * `heldElsewhere`, which cannot tell a runner from a second Neovim: a live
   * runner is something to attach to and steer, another editor is not.
   */
  runnerLive: boolean;
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

/**
 * What one `#turn` call needs. `dial` is required so a call site that forgets
 * it fails to compile — the exact regression this shape exists to prevent —
 * while its own `model`/`effort` fields may still be undefined.
 */
interface TurnSpec {
  dial: Dial;
  prompt: string;
  cwd: string;
  phase: Phase;
  resume: string | null;
  schema?: Record<string, unknown>;
  worktreeRoot?: string;
  /** Present only for a build turn a runner can steer; see `steer.ts`. */
  steering?: SteerControl | undefined;
}

export class BigService {
  readonly #sdk: BigSdk;
  readonly #store: BigStore;
  readonly #claudePath: string;
  readonly #env: Env;
  readonly #emit: EmitEvent;
  readonly #steering: SteerControl | undefined;
  readonly #runner: BigRunner | undefined;
  readonly #heldLock: SessionLock | undefined;
  readonly #steerSettleMs: number;
  readonly #running = new Map<number, Run>();
  readonly #runningByKey = new Map<string, number>();

  constructor(options: BigServiceOptions) {
    this.#sdk = options.sdk;
    this.#store = options.store;
    this.#claudePath = options.claudePath;
    this.#env = subscriptionEnv(options.env);
    this.#emit = options.emit;
    this.#steering = options.steering;
    this.#runner = options.runner;
    this.#heldLock = options.heldLock;
    this.#steerSettleMs = options.steerSettleMs ?? STEER_SETTLE_MS;
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
  async intake(
    requestId: number,
    params: { root: string; id: string; message: string } & Dial,
  ): Promise<SessionView> {
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
        dial: { model: params.model, effort: params.effort },
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
  async build(requestId: number, params: { root: string; id: string } & BuildDial): Promise<SessionView> {
    refuseLowTriage(params);
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
        dial: { model: params.model, effort: params.effort },
        steering: this.#steering,
      });
      session.buildSessionId = result.sessionId;
      session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session, params);
    });
  }

  /** Capture and triage on their own: the recovery path for a detached build. */
  async capture(requestId: number, params: { root: string; id: string } & BuildDial): Promise<SessionView> {
    refuseLowTriage(params);
    const session = this.#requireBuildable(params.root, params.id);
    return this.#run(requestId, session, 'capture', () => this.#captureAndTriage(requestId, session, params));
  }

  /** The reviewer's `r`: send one block's comment back to the build agent. */
  async revise(
    requestId: number,
    params: { root: string; id: string; blockId: string; comment: string } & BuildDial,
  ): Promise<SessionView> {
    refuseLowTriage(params);
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
        dial: { model: params.model, effort: params.effort },
        steering: this.#steering,
      });
      session.buildSessionId = result.sessionId;
      session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session, params);
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
    params: {
      root: string;
      id: string;
      answers: ReadonlyArray<{ blockId: string; text: string }>;
    } & Dial,
  ): Promise<SessionView> {
    // Grading is the gate a substantial thread must clear — running it at the
    // shallowest effort would let the gate itself miss what it exists to catch.
    if (params.effort === 'low') {
      throw new ProtocolError('bad_request', 'grading never runs at effort low — it is the gate');
    }
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
    const answers = normalizeAnswers(params.answers);

    return this.#run(requestId, session, 'grading', async () => {
      // Read INSIDE the claim, exactly as `merge` does: the record above was
      // read before this run held the session.
      const held = this.#store.require(params.root, params.id);
      const diffText = this.#store.readVerifiedDiff(held);
      if (diffText === null) {
        throw new ProtocolError(
          'bad_request',
          'the captured diff is not the one these threads describe — re-triage it',
        );
      }
      const items = buildGradeItems(held, answers, parseUnifiedDiff(diffText));
      const round = await this.#gradeRound(requestId, held, items, threshold, params);
      return this.#recordRound(requestId, params, items, round, threshold);
    });
  }

  /**
   * Writes a finished round onto the record as it stands NOW, re-read rather
   * than reused. A grading turn runs for tens of seconds, and anything written
   * while it ran — the reader's `X` reopening another thread, which is a
   * refusal of the triage and the one thing this gate exists to respect — is on
   * disk and must survive this save.
   */
  #recordRound(
    requestId: number,
    params: { root: string; id: string },
    items: readonly GradeItem[],
    round: RoundResult,
    threshold: number,
  ): SessionView {
    const session = this.#store.require(params.root, params.id);
    if (round.gradeSessionId !== null) session.gradeSessionId = round.gradeSessionId;
    for (const item of items) {
      const block = session.blocks.find((entry) => entry.id === item.threadId);
      if (block === undefined) {
        this.#emit('big.notice', {
          id: requestId,
          text: `'${item.title}' is no longer part of this change — its answer was not recorded`,
        });
        continue;
      }
      block.rounds.push(roundFor(item.threadId, item.answer, round.grades));
      const grade = round.grades.kind === 'graded' ? round.grades.byThread.get(item.threadId) : undefined;
      if (grade !== undefined && clears(grade, threshold)) block.state = 'resolved';
    }
    this.#store.save(session);
    return this.#view(session);
  }

  /**
   * One grading turn for the whole round. Read-only, in the build clone so the
   * grader can check a claim against the code, and resumed across rounds so a
   * follow-up remembers what it already asked.
   *
   * Returns the grader's session rather than writing it: the record this round
   * lands on is re-read afterwards, and mutating the copy read before the turn
   * is exactly the clobber `#recordRound` exists to avoid.
   */
  async #gradeRound(
    requestId: number,
    session: BigSession,
    items: readonly GradeItem[],
    threshold: number,
    dial: Dial,
  ): Promise<RoundResult> {
    const resumed = session.gradeSessionId !== null;
    try {
      const result = await this.#turn(requestId, {
        prompt: composeGradePrompt(session.spec, threshold, items, resumed),
        cwd: session.worktree?.path ?? session.repoRoot,
        phase: 'grade',
        resume: session.gradeSessionId,
        schema: GRADE_SCHEMA,
        dial,
      });
      const byThread = parseGradeOutput(result.structured);
      const grades: RoundGrades =
        byThread === null
          ? this.#ungraded(requestId, 'the grading turn did not return grades')
          : { kind: 'graded', byThread };
      return { grades, gradeSessionId: result.sessionId };
    } catch (cause) {
      if (cause instanceof ProtocolError && cause.code === 'cancelled') throw cause;
      const reason = cause instanceof Error ? cause.message : String(cause);
      return { grades: this.#ungraded(requestId, reason), gradeSessionId: null };
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
   * `e`: the agent explains one thread's hunks in plain language, for a
   * reader who has cleared it (or never had to defend it) but wants the plain
   * reading spelled out.
   *
   * Refused while a substantial thread's defense is still open — explaining
   * it would hand over the answer the gate exists to test. Enforced twice:
   * before the run claims the session (a fast no), and again once it holds
   * the record (another editor could have answered the thread in between).
   */
  async explain(
    requestId: number,
    params: { root: string; id: string; blockId: string } & Dial,
  ): Promise<{ text: string }> {
    const session = this.#store.require(params.root, params.id);
    this.#reconcileOrThrow(session);
    this.#refuseIfHeldElsewhere(session);
    requireExplainable(session, params.blockId);

    return this.#run(requestId, session, 'explaining', async () => {
      const held = this.#store.require(params.root, params.id);
      const block = requireExplainable(held, params.blockId);
      const diffText = this.#store.readVerifiedDiff(held);
      if (diffText === null) {
        throw new ProtocolError('bad_request', 'the captured diff is not the one this thread describes');
      }
      const worktree = held.worktree;
      if (worktree === null || !worktree.ready) {
        throw new ProtocolError('bad_request', 'the build clone is gone — nothing left to explain from');
      }
      const hunks = new Map(parseUnifiedDiff(diffText).hunks.map((hunk) => [hunk.id, hunk]));
      const result = await this.#turn(requestId, {
        prompt: composeExplainPrompt(block, renderBlockDiff(block, hunks)),
        cwd: worktree.path,
        phase: 'explain',
        resume: null,
        dial: { model: params.model, effort: params.effort },
      });
      return { text: result.text };
    });
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
      // Re-read INSIDE the claim: the record above was read before this run
      // held the session, so another editor could have moved it since. What
      // the merge is made on is this, never what the editor asked with.
      const held = this.#store.require(params.root, params.id);
      const refusals = await checkMerge(held, this.#mergeFacts(held, countBlocks(held.blocks)));
      if (refusals.length > 0) {
        await this.#repairLandedRecord(requestId, held, refusals);
        return { session: this.#view(held), merged: false, refusals };
      }

      const base = requireBase(held);
      const baseBranch = base.branch;
      if (baseBranch === null) throw new ProtocolError('internal', 'checkMerge passed a change with no base branch');
      const branch = await this.#freeBranchName(held);
      const patchPath = this.#store.diffPathFor(held.repoRoot, held.id);
      const indexFile = join(this.#store.dirFor(held.repoRoot, held.id), 'merge-index');
      // Pinned to the record BEFORE anything touches the repo: if the write
      // that follows lands but the record write after it does not survive, a
      // repair must recognize this exact attempt by branch and tree, never a
      // sibling session's landing of the same-titled change.
      held.landAttempt = {
        branch,
        tree: await expectedTree({ repoRoot: held.repoRoot, baseCommit: base.commit, patchPath, indexFile }),
      };
      this.#store.save(held);
      this.#emit('big.state', { id: requestId, session: held.id, state: 'reviewing', note: `landing on ${branch}` });
      const landed = await landDiff({
        repoRoot: held.repoRoot,
        branch,
        baseBranch,
        baseCommit: base.commit,
        patchPath,
        message: held.title,
        indexFile,
      });

      return this.#afterLanding(requestId, held, landed, baseBranch, params.cleanup === true);
    });
  }

  /**
   * Bookkeeping AFTER the commit is on the operator's branch. Nothing here can
   * un-land it, so nothing here may read as a failed merge: a record write that
   * throws (a full disk, a store removed under a live run) leaves the change
   * landed, and the reader is told exactly that. The record is repaired on the
   * next merge attempt, which finds the commit and says so.
   */
  async #afterLanding(
    requestId: number,
    session: BigSession,
    landed: LandResult,
    baseBranch: string,
    cleanup: boolean,
  ): Promise<{ session: SessionView; merged: boolean; refusals: MergeRefusal[] }> {
    const at = `${landed.commit.slice(0, 8)} on ${baseBranch}`;
    session.merge = { branch: landed.branch, commit: landed.commit, baseBranch, at: Date.now() };
    transition(session, 'merged', at);
    try {
      this.#store.save(session);
    } catch (cause) {
      this.#emit('big.notice', {
        id: requestId,
        text: `the change LANDED as ${at}, but nvime could not record it: ${messageOf(cause)}`,
      });
      return { session: this.#view(session), merged: true, refusals: [] };
    }
    if (cleanup) {
      try {
        await this.#cleanupClone(session);
      } catch (cause) {
        this.#emit('big.notice', {
          id: requestId,
          text: `the change landed as ${at}; the build clone could not be dropped: ${messageOf(cause)}`,
        });
      }
    }
    return { session: this.#view(session), merged: true, refusals: [] };
  }

  /**
   * Brings a record up to a merge that already happened. `merged-elsewhere`
   * means the commit is on their branch under this session's own branch — the
   * post-land record write did not survive — so the commit is the fact and the
   * record is corrected to it.
   */
  async #repairLandedRecord(
    requestId: number,
    session: BigSession,
    refusals: readonly MergeRefusal[],
  ): Promise<void> {
    if (session.state === 'merged') return;
    if (!refusals.some((refusal) => refusal.code === 'merged-elsewhere')) return;
    const base = session.base;
    if (base === null || base.branch === null) return;
    const landed = await landedAlready(session, base.branch, base.commit);
    if (landed === null) return;
    session.merge = { branch: landed.branch, commit: landed.commit, baseBranch: base.branch, at: Date.now() };
    transition(session, 'merged', `${landed.commit.slice(0, 8)} on ${base.branch} — recorded after the fact`);
    try {
      this.#store.save(session);
    } catch (cause) {
      this.#emit('big.notice', { id: requestId, text: `could not record the landed change: ${messageOf(cause)}` });
    }
  }

  /**
   * Moves the build onto a base branch that has advanced since it started, then
   * re-captures and re-triages. Content the reader already cleared carries
   * forward by signature; anything the move changed comes back open.
   */
  async rebase(requestId: number, params: { root: string; id: string } & BuildDial): Promise<SessionView> {
    refuseLowTriage(params);
    const session = this.#requireBuildable(params.root, params.id);
    const base = requireBase(session);
    const branch = base.branch;
    const worktree = session.worktree;
    if (branch === null || worktree === null) {
      throw new ProtocolError('bad_request', 'this change has no base branch to rebase onto');
    }
    const head = await resolveRef(session.repoRoot, branch);
    if (head === null) throw new ProtocolError('bad_request', `${branch} no longer exists`);
    if (head === base.commit) throw new ProtocolError('bad_request', `${branch} has not moved`);

    return this.#run(requestId, session, 'rebasing', async () => {
      // The fetched commit, not the one read above: the branch may have moved
      // again, and what the clone is rebased ONTO is what the base becomes.
      const fetched = await fetchBase(worktree.path, session.repoRoot, branch);
      const { conflicted } = await rebaseCloneOnto(worktree.path, fetched);
      this.#emit('big.state', {
        id: requestId,
        session: session.id,
        state: 'building',
        note: conflicted ? 'the rebase hit conflicts — resolving them' : 're-verifying on the new base',
      });
      await this.#finishRebase(requestId, session, worktree.path, conflicted, branch, params);
      session.base = { commit: fetched, branch };
      // Whatever was pinned was pinned against the old base; a stale pin here
      // could only ever fail its own parent check, but null says so plainly.
      session.landAttempt = null;
      this.#store.save(session);
      return this.#captureAndTriage(requestId, session, params);
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
    dial: Dial,
  ): Promise<void> {
    const result = await this.#turn(requestId, {
      prompt: composeRebasePrompt(conflicted, baseBranch),
      cwd: clonePath,
      phase: 'build',
      resume: session.buildSessionId,
      worktreeRoot: clonePath,
      dial,
      steering: this.#steering,
    });
    session.buildSessionId = result.sessionId;
    session.conversation.push({ role: 'agent', text: result.text, at: Date.now() });
    // Saved before the check below, which can throw: what the turn said is
    // worth keeping even when the rebase it was resolving had to be undone.
    this.#store.save(session);
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
    for (const candidate of branchCandidates(session.title, session.id)) {
      if ((await resolveRef(session.repoRoot, `refs/heads/${candidate}`)) === null) return candidate;
    }
    const preferred = branchNameFor(session.title, session.id);
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
  async #captureAndTriage(requestId: number, session: BigSession, dial: BuildDial): Promise<SessionView> {
    const worktree = session.worktree;
    if (worktree === null || !worktree.ready) {
      throw new ProtocolError('bad_request', 'this big change has nothing built to capture');
    }
    const base = requireBase(session);
    const previous = session.blocks;
    clearCapture(session);
    // A pinned land attempt names a commit built from the capture just
    // disowned; a fresh triage must stop honoring it as "already landed".
    session.landAttempt = null;
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
    const raw = await this.#triageBlocks(requestId, session, parsed, rendered, dial);
    const armed = gateArmed(session.difficulty);
    const sorted = carryForward(previous, normalizeBlocks(raw, parsed, unshownIds, armed));
    const blocks = withTrivialAck(sorted, parsed.hunks.length, armed);
    transition(session, 'reviewing', `${blocks.length} thread(s) from ${parsed.hunks.length} hunk(s)`);
    this.#store.commitCapture(session, { id: diffId, bytes, blocks });
    return this.#view(session);
  }

  async #triageBlocks(
    requestId: number,
    session: BigSession,
    parsed: ParsedDiff,
    rendered: RenderedTriage,
    dial: BuildDial,
  ): Promise<RawBlock[]> {
    const worktree = session.worktree;
    // Its own model if named; otherwise the build's, so a build+triage pair
    // reads the same code under the same identity by default. Effort never
    // inherits the build's — `#buildOptions` floors an unset gate effort to
    // 'medium' on its own, regardless of what the build turn ran at.
    const triageDial: Dial = { model: dial.triageModel ?? dial.model, effort: dial.triageEffort };
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
        dial: triageDial,
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
    // clone and discard the session out from under this run. A runner hands
    // its own claim in — it took one before it opened the log — and keeps it.
    const held = this.#heldLock;
    const lock = held ?? this.#store.acquireLock(session, what);
    const run: Run = { requestId, key, abort: new AbortController() };
    this.#running.set(requestId, run);
    this.#runningByKey.set(key, requestId);
    // Holding the claim makes this process the record's only writer, so this is
    // the one place the runner field is set and cleared. A sidecar run clears
    // whatever a dead runner left behind; a runner writes its own identity, and
    // the clear in `finally` is skipped when it is killed — which is precisely
    // how a record ends up saying "a runner was driving this, and it is gone".
    this.#writeRunnerField(session, this.#runner ?? null);
    try {
      return await body();
    } catch (cause) {
      throw translate(cause, run.abort);
    } finally {
      this.#running.delete(requestId);
      this.#runningByKey.delete(key);
      this.#writeRunnerField(session, null);
      if (held === undefined) lock.release();
    }
  }

  /**
   * Rewrites ONLY the runner field, on the record as it stands now. A run's
   * body re-reads and saves the record (`merge` and `answer` both do), so
   * saving the object this call started with would silently revert their work.
   */
  #writeRunnerField(session: BigSession, runner: BigRunner | null): void {
    try {
      const held = this.#store.read(session.repoRoot, session.id);
      if (held === null || sameRunner(held.runner, runner)) {
        session.runner = runner;
        return;
      }
      held.runner = runner;
      this.#store.save(held);
      session.runner = runner;
    } catch (cause) {
      // A store removed under a live run. The run itself will fail on its own
      // work; swallowing this would only hide which write went first.
      process.stderr.write(`nvime: could not record the build runner: ${messageOf(cause)}\n`);
    }
  }

  /**
   * One agent turn, streamed into the panel and reduced to its result.
   *
   * A steerable turn is the same turn driven from a stream of user messages
   * instead of one string: each steer the SDK takes runs as a further turn, so
   * this loop keeps the LAST result rather than returning the first, and only
   * ends the input stream once nothing is left to deliver.
   */
  async #turn(requestId: number, spec: TurnSpec): Promise<TurnResult> {
    const abort = this.#abortFor(requestId);
    const options = this.#buildOptions(requestId, spec, abort);
    const steering = spec.steering;
    const prompt = steering === undefined ? spec.prompt : steeredPrompt(spec.prompt, steering);
    let sessionId = spec.resume ?? '';
    let last: TurnResult | null = null;

    try {
      for await (const message of this.#sdk.query({ prompt, options })) {
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
          last = {
            sessionId: sessionId === '' ? message.session_id : sessionId,
            text: message.result,
            structured: message.structured_output,
            usage: readUsage(message.usage),
            costUsd: message.total_cost_usd,
          };
          if (steering === undefined) return last;
          this.#settleSteeredTurn(steering, message.queued_turn_count);
        }
      }
      if (last !== null) return last;
      throw new ProtocolError('agent_error', `the ${spec.phase} turn ended without a result`);
    } finally {
      // However this turn ended, it is no longer reading input. Without this a
      // steer sent during the capture and triage that follow would be accepted
      // by a queue nothing is behind any more.
      steering?.close(STEER_CLOSED);
    }
  }

  /**
   * Decides, at each result of a steered turn, whether the build is over.
   *
   * Measured against the shipped CLI rather than assumed: a message handed over
   * mid-turn is answered by a SECOND result about a second later, and BOTH
   * results report `queued_turn_count: 0` — the field never says "one more
   * follows" here. Trusting it alone would end the input stream between the two
   * and drop the steer's turn; refusing to end it until a second result arrives
   * hangs forever in the other common case, where the agent read the steer
   * inside the turn already running and there is no second result at all.
   *
   * So a turn that took a steer gets a grace window instead of a verdict: the
   * next result cancels it, and its absence ends the build. Nothing is lost
   * either way — a steer already handed over is in the CLI's pipe, and closing
   * the stream flushes it rather than discarding it.
   */
  #settleSteeredTurn(steering: SteerControl, queued: number | undefined): void {
    const owed = steering.awaitingTurn;
    steering.noteTurn();
    if (steering.pending > 0 || (queued ?? 0) > 0) return;
    if (owed) steering.closeAfter(this.#steerSettleMs, STEER_CLOSED);
    else steering.close(STEER_CLOSED);
  }

  #abortFor(requestId: number): AbortController {
    const run = this.#running.get(requestId);
    if (run === undefined) throw new Error(`no live big-change run ${requestId}`);
    return run.abort;
  }

  #buildOptions(requestId: number, spec: TurnSpec, abort: AbortController): Options {
    const build = spec.phase === 'build';
    const gate = GATE_PHASES.has(spec.phase);
    const dial = gateDial(spec.phase, spec.dial);
    const realWorktree = buildWriteBoundary(build, spec.worktreeRoot);
    return {
      cwd: spec.cwd,
      // A copy per turn: the SDK mutates the env object it is handed. A gate
      // turn also loses every MODEL/EFFORT-named env override plus the ambient
      // thinking-depth toggles (stripGateEnv) — not everything that could
      // shape the turn, only what is known to name its own model/effort/depth.
      env: gate ? stripGateEnv(this.#env) : { ...this.#env },
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
      ...dialOptions(dial),
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
      runnerLive: this.#store.liveRunner(session) !== null,
      worktreeExists: this.#store.hasWorktree(session),
      hasDiff: this.#store.hasDiff(session),
      counts,
    };
  }
}

/** Whether two runner records name the same run. Null is "nobody driving it". */
function sameRunner(a: BigRunner | null, b: BigRunner | null): boolean {
  if (a === null || b === null) return a === b;
  return a.pid === b.pid && a.startedAt === b.startedAt;
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

/** A session's in-process key. `\0` cannot occur in a path, so it cannot collide. */
function keyOf(session: BigSession): string {
  return `${session.repoRoot}\0${session.id}`;
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

/**
 * Refuses an explicit `triageEffort: 'low'` before any run starts — mirrors
 * `answer`'s grade-effort refusal: triage decides what the gate reviews, so
 * it never runs at the shallowest effort either.
 */
function refuseLowTriage(dial: BuildDial): void {
  if (dial.triageEffort === 'low') {
    throw new ProtocolError('bad_request', 'triage never runs at effort low — it decides what the gate reviews');
  }
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

/** What one grading turn produced, before any of it reaches the record. */
interface RoundResult {
  grades: RoundGrades;
  /** The grader's SDK session; null when the turn never got one, and then kept. */
  gradeSessionId: string | null;
}

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

/**
 * The explain gate: never while a substantial thread's own defense is still
 * open — a plain-language explanation IS the answer the gate is testing for.
 * Trivia and anything already resolved are always explainable.
 */
function requireExplainable(session: BigSession, blockId: string): TriageBlock {
  const block = session.blocks.find((candidate) => candidate.id === blockId);
  if (block === undefined) throw new ProtocolError('bad_request', `no thread '${blockId}'`);
  if (block.substantial && block.state === 'open') {
    throw new ProtocolError(
      'bad_request',
      'this thread is still open — clear it first; explaining it now would hand over the answer',
    );
  }
  return block;
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
