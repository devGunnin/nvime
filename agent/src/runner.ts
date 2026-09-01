import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { BigService, type BigSdk, type BuildDial, type SessionView } from './big.js';
import { BigStore, type BigRunner } from './bigstore.js';
import { resolveClaudeExecutable } from './env.js';
import type { Env } from './env.js';
import { ProtocolError } from './protocol.js';
import { RunLog } from './runlog.js';
import { serveControl, socketPathFor, type ControlServer } from './runsock.js';
import { SteerQueue } from './steer.js';

/**
 * The detached build runner: one process per build, spawned by the sidecar and
 * then on its own.
 *
 * It holds the session's run claim, owns the SDK session for the build phase,
 * appends every event to the session's log, and serves a control socket so any
 * editor — the one that started it, one opened afterwards, several at once —
 * can attach, steer, and stop it. Capture and triage happen HERE, at the end of
 * the build, so closing the editor still ends with threads ready to review.
 *
 * What it deliberately does not do: change any of the build's powers. The write
 * boundary, the permission callback, the gate's effort floors and the read-only
 * triage turn are all `BigService`'s, unchanged — this process only decides
 * where that service runs and who can watch it.
 */

/** What the sidecar hands the runner. Written to a file; never to argv. */
export interface RunnerJob {
  repoRoot: string;
  sessionId: string;
  storeRoot: string;
  what: 'build' | 'revise' | 'rebase';
  dial: BuildDial;
  /** Only for `revise`. */
  blockId?: string;
  comment?: string;
}

export interface RunnerDeps {
  sdk: BigSdk;
  claudePath: string;
  env: Env;
}

/** The one request id every runner-side event carries; attachers rewrite it. */
const RUNNER_REQUEST_ID = 1;

/**
 * Runs one job to completion. Resolves with the exit code the process should
 * use: 0 when the build reached a terminal event of its own, 1 when it could
 * not even be started.
 */
export async function runJob(job: RunnerJob, deps: RunnerDeps): Promise<number> {
  const store = new BigStore(job.storeRoot);
  const log = new RunLog(store.logPathFor(job.repoRoot, job.sessionId));
  const socket = socketPathFor(deps.env, job.repoRoot, job.sessionId);
  let server: ControlServer | null = null;

  const publish = (event: string, params: Record<string, unknown>): void => {
    const { id: _ignored, ...rest } = params;
    const record = log.append(event, rest);
    server?.broadcast(record);
  };

  const steering = new SteerQueue((message, state) => {
    publish('big.steer', { steerId: message.id, text: message.text, state });
  });
  const runner: BigRunner = { pid: process.pid, socket, log: log.path, what: job.what, startedAt: Date.now() };
  const service = new BigService({
    sdk: deps.sdk,
    store,
    claudePath: deps.claudePath,
    env: deps.env,
    emit: publish,
    steering,
    runner,
  });

  // Graceful stop, whichever way it is asked for: the SDK turn is aborted, the
  // failure path below writes the terminal event, and the claim is released on
  // the way out. Nothing kills this process to stop a build.
  const stop = (): void => {
    steering.close('the build was stopped');
    service.cancel(RUNNER_REQUEST_ID);
  };

  try {
    server = await serveControl(socket, {
      replay: (after) => log.readAfter(after),
      steer: (text) => {
        const result = steering.push(text);
        return result.queued ? { queued: true } : { queued: false, reason: result.reason };
      },
      cancel: stop,
      info: () => ({ pid: process.pid, what: job.what, seq: log.seq }),
    });
    for (const signal of ['SIGTERM', 'SIGINT'] as const) process.once(signal, stop);

    publish('big.state', { session: job.sessionId, state: 'building', note: `detached build (pid ${process.pid})` });
    const view = await dispatch(service, job);
    publish('big.done', {
      session: job.sessionId,
      state: view.display,
      open: view.counts.open,
      total: view.counts.total,
    });
    return 0;
  } catch (cause) {
    // A runner that never got its socket up has nothing to report through: the
    // sidecar's handshake times out and falls back, and it needs the reason on
    // stderr rather than in a log nobody is following.
    if (server === null) throw cause;
    publish('big.failed', failureOf(cause));
    return 0;
  } finally {
    steering.close('the build has finished');
    await server?.close();
    log.close();
  }
}

function dispatch(service: BigService, job: RunnerJob): Promise<SessionView> {
  const base = { root: job.repoRoot, id: job.sessionId, ...job.dial };
  if (job.what === 'build') return service.build(RUNNER_REQUEST_ID, base);
  if (job.what === 'rebase') return service.rebase(RUNNER_REQUEST_ID, base);
  const blockId = job.blockId;
  const comment = job.comment;
  if (blockId === undefined || comment === undefined) {
    throw new ProtocolError('bad_request', 'a revise job needs a blockId and a comment');
  }
  return service.revise(RUNNER_REQUEST_ID, { ...base, blockId, comment });
}

/**
 * The terminal event for a run that ended badly. `cancelled` is separated out:
 * a stopped build is a decision the reader made, not a failure to report as one.
 */
function failureOf(cause: unknown): Record<string, unknown> {
  if (cause instanceof ProtocolError) {
    return {
      code: cause.code,
      message: cause.message,
      ...(cause.detail === undefined ? {} : { detail: cause.detail }),
    };
  }
  return { code: 'agent_error', message: cause instanceof Error ? cause.message : String(cause) };
}

/** Reads and validates the job file the sidecar wrote. */
export function readJob(path: string): RunnerJob {
  const raw = JSON.parse(readFileSync(path, 'utf8')) as RunnerJob;
  if (typeof raw.repoRoot !== 'string' || raw.repoRoot === '') throw new Error('the job names no repo root');
  if (typeof raw.sessionId !== 'string' || raw.sessionId === '') throw new Error('the job names no session');
  if (typeof raw.storeRoot !== 'string' || raw.storeRoot === '') throw new Error('the job names no store root');
  if (raw.what !== 'build' && raw.what !== 'revise' && raw.what !== 'rebase') {
    throw new Error(`the job names an unknown action '${String(raw.what)}'`);
  }
  if (typeof raw.dial !== 'object' || raw.dial === null) throw new Error('the job carries no dial');
  return raw;
}

async function main(): Promise<void> {
  const jobPath = process.argv[2];
  if (jobPath === undefined) {
    process.stderr.write('nvime-runner: usage: nvime-runner <job.json>\n');
    process.exit(2);
  }
  const claudePath = resolveClaudeExecutable(process.env);
  if (claudePath === null) {
    process.stderr.write('nvime-runner: the claude CLI was not found on PATH\n');
    process.exit(2);
  }
  const job = readJob(jobPath);
  const code = await runJob(job, { sdk: { query }, claudePath, env: process.env });
  process.exit(code);
}

/** True when node was pointed at THIS file, rather than importing it. */
function isEntryPoint(): boolean {
  const argv = process.argv[1];
  if (argv === undefined) return false;
  try {
    return realpathSync(argv) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    // A path that no longer resolves is not this module.
    return false;
  }
}

if (isEntryPoint()) {
  void main().catch((cause: unknown) => {
    process.stderr.write(`nvime-runner: ${cause instanceof Error ? (cause.stack ?? cause.message) : String(cause)}\n`);
    process.exit(1);
  });
}
