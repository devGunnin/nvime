import { spawn, type ChildProcess } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { closeSync, fstatSync, mkdirSync, openSync, readSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { BigService, BuildDial, SessionView } from './big.js';
import { isLockLive, type BigSession, type BigStore } from './bigstore.js';
import type { EmitEvent } from './chat.js';
import type { Env } from './env.js';
import { holderMessage } from './merge.js';
import { ProtocolError } from './protocol.js';
import { isTerminal, lastSeqOf, readLogAfter, type RunEvent } from './runlog.js';
import { connectControl, socketPathFor, type ControlClient } from './runsock.js';
import type { RunnerJob } from './runner.js';

/**
 * The sidecar's half of a detached build: start the runner, follow it, and get
 * out of its way.
 *
 * Everything here is recoverable from disk. The runner's identity is on the
 * session record, its output is in an append-only log beside it, and its
 * control socket's path is a pure function of the repo and the session — so an
 * editor started an hour later reaches the same running build as the one that
 * launched it, and neither of them is special.
 */

export type DetachedKind = 'build' | 'revise' | 'rebase';

/** How long to wait for a spawned runner to record itself before giving up. */
export const HANDSHAKE_TIMEOUT_MS = 30_000;

const HANDSHAKE_POLL_MS = 50;

/** How long a stopped runner gets to exit on its own before it is killed. */
export const STOP_GRACE_MS = 5_000;

/**
 * How long a runner that accepted the connection gets to answer the attach.
 * Without it the RPC — deliberately deadline-free on the Lua side, because a
 * build lasts as long as it lasts — waits forever on a runner that connected
 * and then went quiet, and the log backstop never runs.
 */
export const ATTACH_ACK_TIMEOUT_MS = 10_000;

/** How long a just-finished run's own claim gets to clear before `start()`
 *  gives up waiting on it and returns anyway. */
export const CLAIM_RELEASE_TIMEOUT_MS = 5_000;

export interface DetachedOptions {
  big: BigService;
  store: BigStore;
  env: Env;
  emit: EmitEvent;
  /** Overrides `ATTACH_ACK_TIMEOUT_MS`; only a test has a reason to shorten it. */
  attachAckMs?: number | undefined;
}

export interface StartParams extends BuildDial {
  root: string;
  id: string;
  blockId?: string;
  comment?: string;
}

/** One request that is following a runner, so it can be detached or stopped. */
interface Follower {
  client: ControlClient | null;
  session: { root: string; id: string };
  stop: () => void;
}

/** A runner just spawned, and where its stderr stood before it started. */
interface SpawnedRunner {
  child: ChildProcess;
  errFrom: number;
}

type SignalOutcome = 'sent' | 'gone' | 'denied';

export class DetachedService {
  readonly #big: BigService;
  readonly #store: BigStore;
  readonly #env: Env;
  readonly #emit: EmitEvent;
  readonly #followers = new Map<number, Follower>();
  readonly #attachAckMs: number;
  /** This sidecar, as the runner labels the steers it sends. */
  readonly #origin = randomBytes(8).toString('hex');

  constructor(options: DetachedOptions) {
    this.#big = options.big;
    this.#store = options.store;
    this.#env = options.env;
    this.#emit = options.emit;
    this.#attachAckMs = options.attachAckMs ?? ATTACH_ACK_TIMEOUT_MS;
  }

  /**
   * Starts the build in a detached runner and follows it to its end. Falls back
   * to the in-sidecar build — loudly, never silently — when the runner cannot
   * be started at all, because a build that only runs when the machinery is
   * perfect is worse than one that says it is editor-bound this time.
   */
  async start(requestId: number, kind: DetachedKind, params: StartParams): Promise<SessionView> {
    if (!detachedEnabled(this.#env)) return this.#inSidecar(requestId, kind, params);
    const session = this.#store.require(params.root, params.id);
    const held = this.#store.holderOf(session);
    if (held !== null) {
      throw new ProtocolError('busy', `${holderMessage(held)}; attach to it instead`);
    }
    const from = lastSeqOf(this.#store.logPathFor(params.root, params.id));
    let spawned: SpawnedRunner;
    try {
      spawned = this.#spawnRunner(kind, params);
    } catch (cause) {
      return this.#fallback(requestId, kind, params, messageOf(cause));
    }
    const handshake = await this.#awaitRunner(spawned.child, params, from);
    if (handshake === 'failed') {
      this.#refuseIfTakenElsewhere(params);
      return this.#fallback(requestId, kind, params, this.#runnerStderr(params, spawned.errFrom));
    }
    const followed = await this.#follow(requestId, params, from);
    // Only a run that reached a terminal event is still shutting down its
    // claim; a killed runner's is deliberately left stale for later.
    if (followed.ended) await this.#awaitClaimReleased(requestId, params);
    return this.#settle(params, from);
  }

  /**
   * Attaches to a session's build: replays its log from `after`, then follows
   * the runner live. Read-only — an attached viewer watches and steers, and
   * several may watch at once.
   */
  async attach(requestId: number, params: { root: string; id: string; after: number }): Promise<{ seq: number }> {
    this.#store.require(params.root, params.id);
    const followed = await this.#follow(requestId, params, params.after);
    if (followed.ended) await this.#awaitClaimReleased(requestId, params);
    return { seq: followed.cursor };
  }

  /** Hands one message to a running build. Refused when nothing is running. */
  async steer(params: { root: string; id: string; text: string }): Promise<{ queued: boolean }> {
    const client = await this.#dial(params, 'there is no running build to steer');
    try {
      await client.steer(params.text, this.#origin);
      return { queued: true };
    } finally {
      client.close();
    }
  }

  /**
   * Stops a running build. The socket first, so the runner writes its terminal
   * event and releases its claim; the recorded pid only when that fails, and
   * only once the claim has proved that pid is still this build's runner.
   */
  async stop(params: { root: string; id: string }): Promise<{ stopped: boolean }> {
    const session = this.#store.require(params.root, params.id);
    if (session.runner === null) return { stopped: false };
    const token = tokenOf(session);
    if (token !== null) {
      try {
        const client = await connectControl(this.#socketFor(params), token);
        try {
          await client.cancel();
        } finally {
          client.close();
        }
        return { stopped: true };
      } catch (cause) {
        this.#emit('big.notice', { session: params.id, text: `the build runner did not answer: ${messageOf(cause)}` });
      }
    }
    return { stopped: await this.#killLiveRunner(params) };
  }

  /** Stops the build a following request is watching, if there is one. */
  async cancel(requestId: number): Promise<boolean> {
    const follower = this.#followers.get(requestId);
    if (follower === undefined) return false;
    await this.stop(follower.session);
    return true;
  }

  /** Stops following without stopping the build. The runner keeps going. */
  detach(requestId: number): boolean {
    const follower = this.#followers.get(requestId);
    if (follower === undefined) return false;
    follower.stop();
    return true;
  }

  // ---- internals ----------------------------------------------------------

  #inSidecar(requestId: number, kind: DetachedKind, params: StartParams): Promise<SessionView> {
    if (kind === 'build') return this.#big.build(requestId, params);
    if (kind === 'rebase') return this.#big.rebase(requestId, params);
    const blockId = params.blockId;
    const comment = params.comment;
    if (blockId === undefined || comment === undefined) {
      throw new ProtocolError('bad_request', 'a revision needs a thread and a comment');
    }
    return this.#big.revise(requestId, { ...params, blockId, comment });
  }

  #fallback(requestId: number, kind: DetachedKind, params: StartParams, reason: string): Promise<SessionView> {
    this.#emit('big.notice', {
      id: requestId,
      text: `the detached build runner could not start (${reason}) — building in this editor instead, so it will stop if you close Neovim`,
    });
    return this.#inSidecar(requestId, kind, params);
  }

  /**
   * A runner that could not claim the session exits before it writes anything,
   * so "the handshake failed" and "somebody else owns this build" look alike
   * from here. Falling back into the sidecar would only fail again on the same
   * claim, with a worse message.
   */
  #refuseIfTakenElsewhere(params: { root: string; id: string }): void {
    const session = this.#store.read(params.root, params.id);
    const held = session === null ? null : this.#store.holderOf(session);
    if (held === null) return;
    throw new ProtocolError('busy', `${holderMessage(held)}; attach to it instead`);
  }

  #socketFor(params: { root: string; id: string }): string {
    return socketPathFor(this.#env, params.root, params.id);
  }

  #spawnRunner(kind: DetachedKind, params: StartParams): SpawnedRunner {
    const dir = this.#store.dirFor(params.root, params.id);
    mkdirSync(dir, { recursive: true });
    const job: RunnerJob = {
      repoRoot: params.root,
      sessionId: params.id,
      storeRoot: this.#store.root,
      what: kind,
      dial: {
        model: params.model,
        effort: params.effort,
        triageModel: params.triageModel,
        triageEffort: params.triageEffort,
      },
      ...(params.blockId === undefined ? {} : { blockId: params.blockId }),
      ...(params.comment === undefined ? {} : { comment: params.comment }),
    };
    const jobPath = join(dir, 'runner-job.json');
    writeFileSync(jobPath, JSON.stringify(job, null, 2), { mode: 0o600 });

    // stdio to files, not to this process: the runner must survive the sidecar,
    // and a pipe nobody drains would wedge it the moment the editor is gone.
    const out = openSync(join(dir, 'runner.out'), 'a');
    const err = openSync(join(dir, 'runner.err'), 'a');
    try {
      // Where this run's stderr begins. The file is shared with every earlier
      // run, and quoting one of those as this run's reason is a lie.
      const errFrom = fstatSync(err).size;
      const argv = runnerArgv(this.#env);
      const child = spawn(argv[0] as string, [...argv.slice(1), jobPath], {
        cwd: dir,
        detached: true,
        stdio: ['ignore', out, err],
        env: { ...this.#env } as NodeJS.ProcessEnv,
      });
      child.unref();
      return { child, errFrom };
    } finally {
      closeSync(out);
      closeSync(err);
    }
  }

  /**
   * Waits until the runner has claimed the session and written its identity —
   * the only proof that this exact process is driving the build. A run that
   * finished before it could be observed counts too, but only on a clean exit:
   * the runner exits 0 exactly when it wrote a terminal event of its own, so
   * another editor's result can never be mistaken for this child's.
   */
  async #awaitRunner(
    child: ChildProcess,
    params: { root: string; id: string },
    from: number,
  ): Promise<'attached' | 'failed'> {
    let exit: number | null = null;
    child.once('exit', (code) => {
      exit = code ?? 1;
    });
    child.once('error', () => {
      exit = 1;
    });
    const deadline = Date.now() + HANDSHAKE_TIMEOUT_MS;
    for (;;) {
      const session = this.#store.read(params.root, params.id);
      if (session?.runner != null && session.runner.pid === child.pid) return 'attached';
      if (exit === 0 && readLogAfter(this.#store.logPathFor(params.root, params.id), from).events.some(isTerminal)) {
        return 'attached';
      }
      if (exit !== null || Date.now() >= deadline) return 'failed';
      await sleep(HANDSHAKE_POLL_MS);
    }
  }

  /** Waits for a just-ended run's own claim to clear or be replaced by a
   *  newer one — a fast re-claim is not this run's release to wait on. */
  async #awaitClaimReleased(requestId: number, params: { root: string; id: string }): Promise<void> {
    const deadline = Date.now() + CLAIM_RELEASE_TIMEOUT_MS;
    let seen: ClaimGeneration | null = null;
    for (;;) {
      const session = this.#store.read(params.root, params.id);
      const lock = session === null ? null : this.#store.readLock(session);
      if (lock === null || !isLockLive(lock)) return;
      const generation = { owner: lock.owner, pid: lock.pid, startedAt: lock.startedAt };
      if (seen !== null && !sameGeneration(seen, generation)) return;
      seen = generation;
      if (Date.now() >= deadline) {
        this.#emit('big.notice', { id: requestId, text: 'the finished build is still releasing its claim' });
        return;
      }
      await sleep(HANDSHAKE_POLL_MS);
    }
  }

  /**
   * Streams the run into the editor until it ends, and answers with the last
   * seq it delivered.
   *
   * The socket is tried first, and the log is the backstop for all three ways
   * it can fall short: a runner that already exited never answers the dial, one
   * that is mid-shutdown accepts the connection and drops it before serving the
   * replay, and one that is wedged accepts it and never answers at all. The log
   * holds the whole story either way, and re-reading it from the cursor cannot
   * duplicate what the socket already delivered.
   */
  async #follow(
    requestId: number,
    params: { root: string; id: string },
    after: number,
  ): Promise<{ cursor: number; ended: boolean }> {
    const token = tokenOf(this.#store.read(params.root, params.id));
    if (token === null) return this.#replay(requestId, params, after);
    let client: ControlClient;
    try {
      client = await connectControl(this.#socketFor(params), token);
    } catch {
      return this.#replay(requestId, params, after);
    }
    let cursor = after;
    let ended = false;
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      let ackTimer: NodeJS.Timeout | null = null;
      const clearAck = (): void => {
        if (ackTimer === null) return;
        clearTimeout(ackTimer);
        ackTimer = null;
      };
      const finish = (): void => {
        if (settled) return;
        settled = true;
        clearAck();
        this.#followers.delete(requestId);
        client.close();
        resolve();
      };
      ackTimer = setTimeout(() => {
        ackTimer = null;
        this.#emit('big.notice', {
          id: requestId,
          text: 'the build runner took the connection but never answered — following its log instead',
        });
        finish();
      }, this.#attachAckMs);
      ackTimer.unref();
      this.#followers.set(requestId, { client, session: params, stop: finish });
      client.onClose(finish);
      client
        .attach(after, (event) => {
          cursor = Math.max(cursor, event.seq);
          this.#push(requestId, event);
          if (isTerminal(event)) {
            ended = true;
            finish();
          }
        })
        .then((ack) => {
          clearAck();
          this.#noteElided(requestId, ack.elided);
        })
        .catch((cause: unknown) => {
          if (settled) return;
          settled = true;
          clearAck();
          this.#followers.delete(requestId);
          client.close();
          reject(cause instanceof Error ? cause : new Error(String(cause)));
        });
    });
    return ended ? { cursor, ended: true } : this.#replay(requestId, params, cursor);
  }

  /** Emits everything after `from` straight from the log. `ended` is true when
   *  a terminal event was among them — the backstop can deliver one too. */
  #replay(requestId: number, params: { root: string; id: string }, from: number): { cursor: number; ended: boolean } {
    const slice = readLogAfter(this.#store.logPathFor(params.root, params.id), from);
    this.#noteElided(requestId, slice.elided);
    let cursor = from;
    let ended = false;
    for (const event of slice.events) {
      cursor = Math.max(cursor, event.seq);
      this.#push(requestId, event);
      if (isTerminal(event)) ended = true;
    }
    return { cursor, ended };
  }

  /** Says what a replay could not reach, rather than letting it look complete. */
  #noteElided(requestId: number, elided: number): void {
    if (elided <= 0) return;
    this.#emit('big.notice', {
      id: requestId,
      text: `${elided} earlier build events are past the end of what the log replays — this view starts after them`,
    });
  }

  /** One recorded event, re-addressed to the request that is watching it. */
  #push(requestId: number, event: RunEvent): void {
    const params: Record<string, unknown> = { ...event.params, id: requestId, seq: event.seq };
    const origin = event.params.origin;
    // A steer another editor sent must never render as this reader's own.
    if (typeof origin === 'string' || origin === null) params.mine = origin === this.#origin;
    this.#emit(event.event, params);
  }

  /**
   * What the run ended as. Read from the log rather than from the runner: the
   * runner is gone by now, and its terminal event is the record of what it did.
   * One writer per session (the runner claims before it opens the log), so the
   * last terminal event after `from` is this run's own and nobody else's.
   */
  #settle(params: { root: string; id: string }, from: number): SessionView {
    const { events } = readLogAfter(this.#store.logPathFor(params.root, params.id), from);
    const terminal = events.filter(isTerminal).pop();
    if (terminal === undefined) {
      // The channel closed with no terminal event: the runner was killed rather
      // than stopped. The session is left `building` with a stale claim, which
      // is exactly what it is — never reported as a finished build.
      throw new ProtocolError(
        'agent_error',
        'the build runner stopped without finishing',
        'the change is still resumable — its clone and its progress are intact',
      );
    }
    if (terminal.event === 'big.failed') {
      const recorded = terminal.params;
      throw new ProtocolError(
        codeOf(recorded.code),
        String(recorded.message ?? 'the detached build failed'),
        typeof recorded.detail === 'string' ? recorded.detail : undefined,
      );
    }
    return this.#big.open(params.root, params.id);
  }

  async #dial(params: { root: string; id: string }, absent: string): Promise<ControlClient> {
    const session = this.#store.require(params.root, params.id);
    const token = tokenOf(session);
    if (token === null) throw new ProtocolError('bad_request', absent);
    try {
      return await connectControl(this.#socketFor(params), token);
    } catch (cause) {
      throw new ProtocolError('bad_request', absent, messageOf(cause));
    }
  }

  /**
   * The kill fallback, and the proof it demands.
   *
   * `session.runner` is DELIBERATELY left behind by a killed runner — that is
   * what makes "build died — resumable" readable — so the one state this path
   * fires in is the state where the recorded pid most likely belongs to
   * somebody else's process by now. Nothing is signalled until the session's
   * claim proves the pid is still this build's runner: the claim's heartbeat is
   * refreshed only by the runner itself, so a recycled pid cannot pass.
   */
  async #killLiveRunner(params: { root: string; id: string }): Promise<boolean> {
    const session = this.#store.read(params.root, params.id);
    const runner = session === null ? null : this.#store.liveRunner(session);
    if (runner === null) {
      this.#emit('big.notice', {
        session: params.id,
        text: 'that build had already died — nothing was stopped, and it is still resumable',
      });
      return false;
    }
    return this.#killRunner(runner.pid);
  }

  /** SIGTERM, then SIGKILL if it is still there. Only ever the recorded pid. */
  async #killRunner(pid: number): Promise<boolean> {
    if (!Number.isInteger(pid) || pid <= 1) return false;
    // `denied` is a process this user may not signal, which a runner of ours
    // never is. Reporting it as stopped would claim a build we never touched.
    if (signal(pid, 'SIGTERM') !== 'sent') return false;
    const deadline = Date.now() + STOP_GRACE_MS;
    while (Date.now() < deadline) {
      if (signal(pid, 0) === 'gone') return true;
      await sleep(HANDSHAKE_POLL_MS);
    }
    return signal(pid, 'SIGKILL') !== 'denied';
  }

  /** The reason THIS run gave, from where its stderr began. Never an older run's. */
  #runnerStderr(params: { root: string; id: string }, from: number): string {
    const path = join(this.#store.dirFor(params.root, params.id), 'runner.err');
    let fd: number;
    try {
      fd = openSync(path, 'r');
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code;
      // Absent is the spawn itself failing; anything else is worth saying,
      // because "wrote nothing" would read as a diagnosis it is not.
      if (code === 'ENOENT' || code === 'ENOTDIR') return 'the runner wrote nothing';
      return `the runner's output could not be read: ${messageOf(cause)}`;
    }
    try {
      const size = fstatSync(fd).size;
      if (size <= from) return 'the runner wrote nothing';
      const buffer = Buffer.allocUnsafe(size - from);
      const got = readSync(fd, buffer, 0, buffer.length, from);
      // The FIRST line, not the last: the message is at the top and the stack
      // frames follow it, and a bare frame explains nothing.
      const lines = buffer.subarray(0, got).toString('utf8').split('\n');
      return lines.find((line) => line.trim() !== '')?.trim() ?? 'the runner wrote nothing';
    } finally {
      closeSync(fd);
    }
  }
}

/**
 * How the runner is launched. Defaults to this bundle's sibling `runner.js`
 * under the same node; `NVIME_RUNNER_ARGV` (a JSON array) replaces the command,
 * which is how the tests run the runner from source with a scripted SDK.
 */
export function runnerArgv(env: Env): string[] {
  const override = env.NVIME_RUNNER_ARGV;
  if (override !== undefined && override !== '') {
    const parsed: unknown = JSON.parse(override);
    if (!Array.isArray(parsed) || parsed.length === 0 || parsed.some((entry) => typeof entry !== 'string')) {
      throw new ProtocolError('bad_request', 'NVIME_RUNNER_ARGV must be a non-empty JSON array of strings');
    }
    return parsed as string[];
  }
  return [process.execPath, join(dirname(fileURLToPath(import.meta.url)), 'runner.js')];
}

/** `NVIME_DETACHED=0` keeps every build inside the sidecar, as it was before. */
export function detachedEnabled(env: Env): boolean {
  return env.NVIME_DETACHED !== '0';
}

/**
 * The control token of the runner the record names, or null when there is
 * nothing to dial. Checked rather than trusted: a record an older sidecar
 * wrote carries a runner with no token, and nothing may reach that socket.
 */
function tokenOf(session: BigSession | null): string | null {
  const token = session?.runner?.token;
  return typeof token === 'string' && token !== '' ? token : null;
}

type ClaimGeneration = { owner: string; pid: number; startedAt: number };

/** Whether two claim snapshots name the same run, not merely the same session. */
function sameGeneration(a: ClaimGeneration, b: ClaimGeneration): boolean {
  return a.owner === b.owner && a.pid === b.pid && a.startedAt === b.startedAt;
}

function signal(pid: number, sig: NodeJS.Signals | 0): SignalOutcome {
  try {
    process.kill(pid, sig);
    return 'sent';
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code === 'ESRCH') return 'gone';
    if (code === 'EPERM') return 'denied';
    throw cause;
  }
}

function codeOf(value: unknown): ProtocolError['code'] {
  return typeof value === 'string' && value !== '' ? (value as ProtocolError['code']) : 'agent_error';
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
