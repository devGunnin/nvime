import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import type { HookInput, HookJSONOutput, Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import {
  composeBuildPrompt,
  composeIntakeOpening,
  composeRevisionPrompt,
  composeTriagePrompt,
  INTAKE_SCHEMA,
  parseIntakeOutput,
} from './bigprompts.js';
import {
  clearCapture,
  reconcile,
  transition,
  type BigSession,
  type BigSpec,
  type BigState,
  type BigStore,
  type BigWorktree,
  type Reality,
} from './bigstore.js';
import type { EmitEvent, SdkBindings } from './chat.js';
import { subscriptionEnv, type Env } from './env.js';
import { captureDiff, cloneAt, readHead, removeClone } from './git.js';
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
import { parseUnifiedDiff, renderForTriage, type ParsedDiff, type RenderedTriage } from './unidiff.js';

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

type Phase = 'intake' | 'build' | 'triage';

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

  create(root: string, title: string): SessionView {
    return this.#view(this.#store.create(root, title));
  }

  list(root: string): SessionSummary[] {
    return this.#store.list(root).map((session) => {
      const view = this.#view(session);
      return {
        id: view.id,
        title: view.title,
        display: view.display,
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
    session.worktree = {
      path: this.#store.worktreePathFor(session.repoRoot, session.id),
      baseCommit: head.commit,
      baseBranch: head.branch,
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

    if (session.state !== 'building') transition(session, 'building', 'rebuilding');
    this.#store.save(session);

    return this.#run(requestId, session, 'build', async () => {
      await this.#ensureClone(requestId, session, worktree);
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

  /** The reviewer's `X`: reopen an auto-resolved thread, or resolve it again. */
  toggleBlock(root: string, id: string, blockId: string, resolved: boolean): SessionView {
    const session = this.#store.require(root, id);
    const block = session.blocks.find((entry) => entry.id === blockId);
    if (block === undefined) throw new ProtocolError('bad_request', `no thread '${blockId}'`);
    if (block.substantial && resolved) {
      throw new ProtocolError('bad_request', 'a substantial thread is cleared by the review gate, not by hand');
    }
    block.state = resolved ? 'resolved' : 'open';
    block.reopened = !resolved;
    this.#store.save(session);
    return this.#view(session);
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
  async #ensureClone(requestId: number, session: BigSession, worktree: BigWorktree): Promise<void> {
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
    await cloneAt(session.repoRoot, worktree.path, worktree.baseCommit);
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
    const previous = session.blocks;
    clearCapture(session);
    transition(session, 'triaging', 'capturing the diff');
    this.#emit('big.state', { id: requestId, session: session.id, state: 'triaging' });
    this.#store.save(session);

    const text = await captureDiff(worktree.path, worktree.baseCommit);
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
    const blocks = carryForward(previous, normalizeBlocks(raw, parsed, unshownIds));
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
