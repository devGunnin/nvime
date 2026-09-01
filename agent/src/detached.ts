import { spawn, type ChildProcess } from 'node:child_process';
import { closeSync, mkdirSync, openSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { BigService, BuildDial, SessionView } from './big.js';
import type { BigStore } from './bigstore.js';
import type { EmitEvent } from './chat.js';
import type { Env } from './env.js';
import { ProtocolError } from './protocol.js';
import { isTerminal, readEventsAfter, type RunEvent } from './runlog.js';
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

export interface DetachedOptions {
  big: BigService;
  store: BigStore;
  env: Env;
  emit: EmitEvent;
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

export class DetachedService {
  readonly #big: BigService;
  readonly #store: BigStore;
  readonly #env: Env;
  readonly #emit: EmitEvent;
  readonly #followers = new Map<number, Follower>();

  constructor(options: DetachedOptions) {
    this.#big = options.big;
    this.#store = options.store;
    this.#env = options.env;
    this.#emit = options.emit;
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
    const live = this.#store.foreignLock(session);
    if (live !== null) {
      throw new ProtocolError('busy', `this big change is already running (${live.what}) — attach to it instead`);
    }
    const from = lastSeqOfSession(this.#store, params);
    let child: ChildProcess;
    try {
      child = this.#spawnRunner(kind, params);
    } catch (cause) {
      return this.#fallback(requestId, kind, params, messageOf(cause));
    }
    const handshake = await this.#awaitRunner(child, params, from);
    if (handshake === 'failed') {
      return this.#fallback(requestId, kind, params, this.#runnerStderr(params));
    }
    await this.#follow(requestId, params, from);
    return this.#settle(params, from);
  }

  /**
   * Attaches to a session's build: replays its log from `after`, then follows
   * the runner live. Read-only — an attached viewer watches and steers, and
   * several may watch at once.
   */
  async attach(requestId: number, params: { root: string; id: string; after: number }): Promise<{ seq: number }> {
    this.#store.require(params.root, params.id);
    return { seq: await this.#follow(requestId, params, params.after) };
  }

  /** Hands one message to a running build. Refused when nothing is running. */
  async steer(params: { root: string; id: string; text: string }): Promise<{ queued: boolean }> {
    const client = await this.#dial(params, 'there is no running build to steer');
    try {
      await client.steer(params.text);
      return { queued: true };
    } finally {
      client.close();
    }
  }

  /**
   * Stops a running build. The socket first, so the runner writes its terminal
   * event and releases its claim; the recorded pid only when that fails, and
   * only that pid — never a name, which would reach someone else's runner.
   */
  async stop(params: { root: string; id: string }): Promise<{ stopped: boolean }> {
    const session = this.#store.require(params.root, params.id);
    const runner = session.runner;
    if (runner === null) return { stopped: false };
    try {
      const client = await connectControl(this.#socketFor(params));
      try {
        await client.cancel();
      } finally {
        client.close();
      }
      return { stopped: true };
    } catch (cause) {
      this.#emit('big.notice', { session: params.id, text: `the build runner did not answer: ${messageOf(cause)}` });
      return { stopped: await this.#killRunner(runner.pid) };
    }
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

  #socketFor(params: { root: string; id: string }): string {
    return socketPathFor(this.#env, params.root, params.id);
  }

  #spawnRunner(kind: DetachedKind, params: StartParams): ChildProcess {
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
      const argv = runnerArgv(this.#env);
      const child = spawn(argv[0] as string, [...argv.slice(1), jobPath], {
        cwd: dir,
        detached: true,
        stdio: ['ignore', out, err],
        env: { ...this.#env } as NodeJS.ProcessEnv,
      });
      child.unref();
      return child;
    } finally {
      closeSync(out);
      closeSync(err);
    }
  }

  /**
   * Waits until the runner has claimed the session and written its identity —
   * the only proof that this exact process is driving the build. A run that
   * finished before it could be observed counts too: the terminal event in the
   * log is the same evidence, arriving in a different order.
   */
  async #awaitRunner(
    child: ChildProcess,
    params: { root: string; id: string },
    from: number,
  ): Promise<'attached' | 'failed'> {
    let exited = false;
    child.once('exit', () => {
      exited = true;
    });
    child.once('error', () => {
      exited = true;
    });
    const deadline = Date.now() + HANDSHAKE_TIMEOUT_MS;
    for (;;) {
      const session = this.#store.read(params.root, params.id);
      if (session?.runner != null && session.runner.pid === child.pid) return 'attached';
      if (readEventsAfter(this.#store.logPathFor(params.root, params.id), from).some(isTerminal)) return 'attached';
      if (exited || Date.now() >= deadline) return 'failed';
      await sleep(HANDSHAKE_POLL_MS);
    }
  }

  /**
   * Streams the run into the editor until it ends, and answers with the last
   * seq it delivered.
   *
   * The socket is tried first, and the log is the backstop for both ways it can
   * fall short: a runner that already exited never answers the dial at all, and
   * one that is mid-shutdown accepts the connection and drops it before serving
   * the replay. Either way the log holds the whole story, and re-reading it
   * from the cursor cannot duplicate what the socket already delivered.
   */
  async #follow(requestId: number, params: { root: string; id: string }, after: number): Promise<number> {
    let client: ControlClient;
    try {
      client = await connectControl(this.#socketFor(params));
    } catch {
      return this.#replay(requestId, params, after);
    }
    let cursor = after;
    let ended = false;
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const finish = (): void => {
        if (settled) return;
        settled = true;
        this.#followers.delete(requestId);
        client.close();
        resolve();
      };
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
        .catch((cause: unknown) => {
          if (settled) return;
          settled = true;
          this.#followers.delete(requestId);
          client.close();
          reject(cause instanceof Error ? cause : new Error(String(cause)));
        });
    });
    return ended ? cursor : this.#replay(requestId, params, cursor);
  }

  /** Emits everything after `from` straight from the log. Returns the new cursor. */
  #replay(requestId: number, params: { root: string; id: string }, from: number): number {
    let cursor = from;
    for (const event of readEventsAfter(this.#store.logPathFor(params.root, params.id), from)) {
      cursor = Math.max(cursor, event.seq);
      this.#push(requestId, event);
    }
    return cursor;
  }

  /** One recorded event, re-addressed to the request that is watching it. */
  #push(requestId: number, event: RunEvent): void {
    this.#emit(event.event, { ...event.params, id: requestId, seq: event.seq });
  }

  /**
   * What the run ended as. Read from the log rather than from the runner: the
   * runner is gone by now, and its terminal event is the record of what it did.
   */
  #settle(params: { root: string; id: string }, from: number): SessionView {
    const events = readEventsAfter(this.#store.logPathFor(params.root, params.id), from);
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
    if (session.runner === null) throw new ProtocolError('bad_request', absent);
    try {
      return await connectControl(this.#socketFor(params));
    } catch (cause) {
      throw new ProtocolError('bad_request', absent, messageOf(cause));
    }
  }

  /** SIGTERM, then SIGKILL if it is still there. Only ever the recorded pid. */
  async #killRunner(pid: number): Promise<boolean> {
    if (!Number.isInteger(pid) || pid <= 1) return false;
    if (!signal(pid, 'SIGTERM')) return false;
    const deadline = Date.now() + STOP_GRACE_MS;
    while (Date.now() < deadline) {
      if (!signal(pid, 0)) return true;
      await sleep(HANDSHAKE_POLL_MS);
    }
    return signal(pid, 'SIGKILL');
  }

  #runnerStderr(params: { root: string; id: string }): string {
    try {
      const text = readFileSync(join(this.#store.dirFor(params.root, params.id), 'runner.err'), 'utf8').trim();
      const lines = text.split('\n');
      return lines[lines.length - 1] ?? 'no output';
    } catch {
      // Nothing was written: the spawn itself is what failed.
      return 'the runner wrote nothing';
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

function lastSeqOfSession(store: BigStore, params: { root: string; id: string }): number {
  const events = readEventsAfter(store.logPathFor(params.root, params.id), 0);
  return events[events.length - 1]?.seq ?? 0;
}

function signal(pid: number, sig: NodeJS.Signals | 0): boolean {
  try {
    process.kill(pid, sig);
    return true;
  } catch (cause) {
    // EPERM means it is alive and someone else's; ESRCH means it is gone.
    return (cause as NodeJS.ErrnoException).code === 'EPERM';
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
