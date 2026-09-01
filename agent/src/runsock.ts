import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { chmodSync, closeSync, lstatSync, mkdirSync, openSync, rmSync, statSync, unlinkSync } from 'node:fs';
import { connect, createServer, type Server, type Socket } from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import type { Env } from './env.js';
import { LineSplitter, ProtocolError } from './protocol.js';
import type { LogSlice, RunEvent } from './runlog.js';

/**
 * The control channel into a running detached build: one unix domain socket per
 * session, served by the runner and dialled by any editor that wants to watch,
 * steer, or stop it.
 *
 * The path is deliberately NOT in the session store. A store path is
 * `<data>/nvime/big/<repo-slug>/<session>/…`, which under a long `$HOME` is
 * already close to the ~104-byte limit `sun_path` imposes — a limit that fails
 * at bind time with a truncated path rather than an error naming the cause.
 * A short runtime directory plus a hash of the session keeps it well inside.
 *
 * Trust model: the directory is 0700 and the socket 0600, so the channel is
 * reachable by processes running as this user and nobody else. That is a real
 * boundary but not a narrow one — the build agent itself runs as this user —
 * so every frame must also carry the session's own token, which lives only in
 * the 0600 session record. See the README's detached section.
 */

/**
 * The shortest of the documented `sun_path` limits (Linux 108, macOS 104),
 * minus room for the trailing NUL and a little slack.
 */
export const MAX_SOCKET_PATH_BYTES = 100;

/** How long a dial waits for the runner to accept before giving up. */
export const CONNECT_TIMEOUT_MS = 5_000;

/** How long a bind claim beside the socket may stand before it is stale. */
const BIND_CLAIM_STALE_MS = 30_000;

/** How much of a steer's origin label is kept. It is only ever rendered. */
const MAX_ORIGIN_CHARS = 64;

/** The shared head of every control frame. The token gates all four ops. */
interface ControlFrame {
  rid: number;
  token: string;
}

/** One request over the control channel, and the runner's answer. */
export type ControlRequest =
  | (ControlFrame & { op: 'attach'; after: number })
  | (ControlFrame & { op: 'steer'; text: string; from: string | null })
  | (ControlFrame & { op: 'cancel' })
  | (ControlFrame & { op: 'ping' });

export interface RunnerInfo {
  pid: number;
  /** What the runner is doing — `build`, `revise`, `rebase`. */
  what: string;
  /** The last event the runner has written, so an attacher can size a replay. */
  seq: number;
}

/** What the runner does with each request. Every one of them is a real action. */
export interface ControlHandlers {
  /** Events after `seq`, read from the log the runner is appending to. */
  replay(after: number): LogSlice;
  /**
   * Queues one steer for the build agent, or says why it cannot be taken.
   * `from` labels the client that sent it, so a viewer can tell its own steer
   * from another editor's; null when the sender did not name itself.
   */
  steer(text: string, from: string | null): { queued: true } | { queued: false; reason: string };
  /** Graceful stop: abort the turn, write the terminal event, release the lock. */
  cancel(): void;
  info(): RunnerInfo;
}

export interface ControlServer {
  /** Sends one event to every attached viewer. Broadcast, so several can watch. */
  broadcast(event: RunEvent): void;
  readonly attached: number;
  close(): Promise<void>;
}

/** A fresh secret for one runner's control channel. */
export function newControlToken(): string {
  return randomBytes(16).toString('hex');
}

/**
 * Where this session's control socket lives. A pure function of the repo and
 * the session id, so an editor that never saw the runner start can still find
 * it — the session record carries the same path for the record, not as the
 * only way to reach it.
 *
 * @throws ProtocolError when no candidate directory yields a short enough path.
 */
export function socketPathFor(env: Env, repoRoot: string, sessionId: string): string {
  if (repoRoot === '' || sessionId === '') throw new TypeError('socketPathFor needs a repo root and a session id');
  const key = createHash('sha256').update(`${repoRoot}\0${sessionId}`).digest('hex').slice(0, 16);
  const candidates = socketDirCandidates(env);
  for (const dir of candidates) {
    const path = join(dir, `${key}.sock`);
    if (Buffer.byteLength(path, 'utf8') <= MAX_SOCKET_PATH_BYTES) return path;
  }
  throw new ProtocolError(
    'agent_error',
    'no directory short enough to hold the build runner socket',
    `tried ${candidates.join(', ')} — a unix socket path may be at most ${MAX_SOCKET_PATH_BYTES} bytes`,
  );
}

/** Runtime dir first, then a per-uid directory under the system temp dir. */
function socketDirCandidates(env: Env): string[] {
  const dirs: string[] = [];
  const runtime = env.XDG_RUNTIME_DIR;
  if (runtime !== undefined && runtime !== '' && isAbsolute(runtime)) dirs.push(join(runtime, 'nvime'));
  dirs.push(join(tmpdir(), `nvime-${process.getuid?.() ?? 0}`));
  return dirs;
}

/**
 * Makes the socket's directory, private to this user.
 *
 * The temp-dir candidate is a shared, world-writable parent, so the directory
 * is checked as well as created: anything that is not a real directory this
 * user owns with no group or other access is refused rather than served from.
 */
export function ensureSocketDir(path: string): string {
  const dir = dirname(path);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  // `lstat`, not `stat`: a symlink planted where the directory should be is the
  // whole point of the check, and following it would hide exactly that.
  const stats = lstatSync(dir);
  if (!stats.isDirectory()) {
    throw new ProtocolError('agent_error', `${dir} is not a directory — refusing to serve a socket there`);
  }
  const uid = process.getuid?.();
  if (uid !== undefined && stats.uid !== uid) {
    throw new ProtocolError('agent_error', `${dir} belongs to another user — refusing to serve a socket there`);
  }
  // Ours, so tightening it is right; mkdir's mode is masked by umask, and an
  // existing directory keeps whatever mode it already had.
  chmodSync(dir, 0o700);
  return dir;
}

/**
 * Serves the control channel. `replay` and the live subscription are wired in
 * the SAME synchronous step, so an attacher can neither miss an event written
 * between the two nor be sent one twice.
 *
 * `token` is required on every frame; a frame without it is answered with an
 * error and the connection dropped.
 */
export async function serveControl(path: string, handlers: ControlHandlers, token: string): Promise<ControlServer> {
  if (token === '') throw new TypeError('serveControl needs a token');
  ensureSocketDir(path);
  const viewers = new Set<Socket>();
  const server = createServer((socket) => {
    socket.setEncoding('utf8');
    wireConnection(socket, viewers, handlers, token);
  });
  await listenAt(server, path);
  // The 0700 directory is the first guard; this is the one that survives a
  // directory mode that is ever wrong. `listen` applies the umask, not a mode.
  chmodSync(path, 0o600);
  return {
    broadcast: (event) => {
      const line = `${JSON.stringify({ op: 'event', event })}\n`;
      for (const viewer of viewers) viewer.write(line);
    },
    get attached() {
      return viewers.size;
    },
    close: async () => {
      for (const viewer of viewers) viewer.destroy();
      viewers.clear();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(path, { force: true });
    },
  };
}

/**
 * Binds, clearing a socket file no runner is behind.
 *
 * The takeover is three steps — probe, unlink, bind — and must be one. Without
 * a claim across them two contenders both probe a leftover file, both see
 * nothing behind it, both unlink and both bind: the loser then serves an inode
 * no dial can reach while believing it owns the session.
 */
async function listenAt(server: Server, path: string): Promise<void> {
  try {
    await bind(server, path);
    return;
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code !== 'EADDRINUSE') throw cause;
  }
  const release = claimBind(`${path}.bind`);
  try {
    if (await isServed(path)) {
      throw new ProtocolError('busy', 'another build runner is already serving this session');
    }
    rmSync(path, { force: true });
    await bind(server, path);
  } finally {
    release();
  }
}

/**
 * Exclusive-creates the takeover claim and answers with its release. A claim a
 * killed runner left behind is removed only when it is both stale AND still the
 * exact file just observed — a compare-and-delete, so a contender racing a
 * faster one never deletes the claim that faster one has since written.
 */
function claimBind(path: string): () => void {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      closeSync(openSync(path, 'wx', 0o600));
      return () => rmSync(path, { force: true });
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code !== 'EEXIST') throw cause;
    }
    const held = statSync(path, { throwIfNoEntry: false });
    if (held === undefined) continue;
    if (Date.now() - held.mtimeMs < BIND_CLAIM_STALE_MS) break;
    removeIfUnchanged(path, held.ino);
  }
  throw new ProtocolError('busy', 'another build runner is taking over this session socket');
}

function removeIfUnchanged(path: string, expectedIno: number): void {
  try {
    if (statSync(path).ino !== expectedIno) return;
    unlinkSync(path);
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
  }
}

function bind(server: Server, path: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    const onError = (cause: Error): void => reject(cause);
    server.once('error', onError);
    server.listen(path, () => {
      server.removeListener('error', onError);
      resolve();
    });
  });
}

/** Whether something is actually listening on `path`, as opposed to a leftover file. */
export function isServed(path: string): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const socket = connect(path);
    const settle = (served: boolean): void => {
      socket.destroy();
      resolve(served);
    };
    socket.once('connect', () => settle(true));
    socket.once('error', () => settle(false));
    socket.setTimeout(CONNECT_TIMEOUT_MS, () => settle(false));
  });
}

function wireConnection(socket: Socket, viewers: Set<Socket>, handlers: ControlHandlers, token: string): void {
  const splitter = new LineSplitter();
  const cleanup = (): void => {
    viewers.delete(socket);
  };
  socket.on('data', (chunk: string) => {
    let lines: string[];
    try {
      lines = splitter.push(chunk);
    } catch (cause) {
      socket.write(`${JSON.stringify({ op: 'error', rid: 0, message: String(cause) })}\n`);
      socket.destroy();
      return;
    }
    for (const line of lines) serveLine(line, socket, viewers, handlers, token);
  });
  socket.on('error', cleanup);
  socket.on('close', cleanup);
}

function serveLine(
  line: string,
  socket: Socket,
  viewers: Set<Socket>,
  handlers: ControlHandlers,
  token: string,
): void {
  let request: ControlRequest;
  try {
    request = parseControlRequest(line);
  } catch (cause) {
    socket.write(`${JSON.stringify({ op: 'error', rid: 0, message: messageOf(cause) })}\n`);
    return;
  }
  const reply = (payload: Record<string, unknown>): void => {
    socket.write(`${JSON.stringify({ ...payload, rid: request.rid })}\n`);
  };
  if (!sameToken(token, request.token)) {
    // Nothing further on this connection is trusted: a caller that cannot name
    // the session's token has no business holding one open.
    reply({ op: 'error', message: 'that is not this build runner’s token' });
    socket.destroy();
    return;
  }
  try {
    serveRequest(request, socket, viewers, handlers, reply);
  } catch (cause) {
    reply({ op: 'error', message: messageOf(cause) });
  }
}

function serveRequest(
  request: ControlRequest,
  socket: Socket,
  viewers: Set<Socket>,
  handlers: ControlHandlers,
  reply: (payload: Record<string, unknown>) => void,
): void {
  if (request.op === 'ping') {
    reply({ op: 'ack', ...handlers.info() });
    return;
  }
  if (request.op === 'steer') {
    const result = handlers.steer(request.text, request.from);
    reply(result.queued ? { op: 'ack', queued: true } : { op: 'error', message: result.reason });
    return;
  }
  if (request.op === 'cancel') {
    reply({ op: 'ack' });
    handlers.cancel();
    return;
  }
  // Replay and subscribe in one step, with nothing awaited between them: an
  // event appended in the gap would otherwise be lost to this viewer entirely.
  // The backlog goes out BEFORE the subscription, so a live event broadcast in
  // the same tick cannot land ahead of the history it belongs after.
  const backlog = handlers.replay(request.after);
  for (const event of backlog.events) socket.write(`${JSON.stringify({ op: 'event', event })}\n`);
  viewers.add(socket);
  reply({ op: 'ack', replayed: backlog.events.length, elided: backlog.elided, seq: handlers.info().seq });
}

/** Validates one incoming control frame at the boundary, before it is acted on. */
export function parseControlRequest(line: string): ControlRequest {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch (cause) {
    throw new ProtocolError('bad_request', `malformed control frame: ${messageOf(cause)}`);
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new ProtocolError('bad_request', 'a control frame must be a JSON object');
  }
  const frame = raw as Record<string, unknown>;
  const rid = frame.rid;
  if (typeof rid !== 'number' || !Number.isSafeInteger(rid)) {
    throw new ProtocolError('bad_request', 'control frame rid must be a safe integer');
  }
  const token = frame.token;
  if (typeof token !== 'string' || token === '') {
    throw new ProtocolError('bad_request', 'a control frame must carry the session token');
  }
  const head = { rid, token };
  if (frame.op === 'ping') return { ...head, op: 'ping' };
  if (frame.op === 'cancel') return { ...head, op: 'cancel' };
  if (frame.op === 'attach') {
    const after = frame.after ?? 0;
    if (typeof after !== 'number' || !Number.isInteger(after) || after < 0) {
      throw new ProtocolError('bad_request', 'attach.after must be a seq >= 0');
    }
    return { ...head, op: 'attach', after };
  }
  if (frame.op === 'steer') {
    if (typeof frame.text !== 'string' || frame.text.trim() === '') {
      throw new ProtocolError('bad_request', 'steer.text must be a non-empty string');
    }
    const from = frame.from;
    if (from !== undefined && from !== null && typeof from !== 'string') {
      throw new ProtocolError('bad_request', 'steer.from must be a string when it is given');
    }
    return {
      ...head,
      op: 'steer',
      text: frame.text,
      from: typeof from === 'string' && from !== '' ? from.slice(0, MAX_ORIGIN_CHARS) : null,
    };
  }
  throw new ProtocolError('bad_request', `unknown control op ${String(frame.op)}`);
}

/** Constant-time for equal lengths, and length itself is not a secret here. */
function sameToken(expected: string, given: string): boolean {
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(given, 'utf8');
  return a.length === b.length && timingSafeEqual(a, b);
}

export interface AttachAck {
  replayed: number;
  /** Events the runner's log no longer replays, because they fell out of the window. */
  elided: number;
  seq: number;
}

export interface ControlClient {
  /** Replays everything after `after`, then follows live. Resolves once attached. */
  attach(after: number, onEvent: (event: RunEvent) => void): Promise<AttachAck>;
  /** `from` labels this client on the recorded steer; null leaves it unnamed. */
  steer(text: string, from: string | null): Promise<void>;
  cancel(): Promise<void>;
  ping(): Promise<RunnerInfo>;
  /** Called when the runner closes the channel — its exit, seen from here. */
  onClose(fn: () => void): void;
  close(): void;
}

/** Dials a runner's control channel. Rejects when nothing is listening. */
export async function connectControl(
  path: string,
  token: string,
  timeoutMs = CONNECT_TIMEOUT_MS,
): Promise<ControlClient> {
  if (token === '') throw new TypeError('connectControl needs a token');
  const socket = await dial(path, timeoutMs);
  return wireClient(socket, token);
}

function dial(path: string, timeoutMs: number): Promise<Socket> {
  return new Promise<Socket>((resolve, reject) => {
    const socket = connect(path);
    socket.setEncoding('utf8');
    const fail = (cause: Error): void => {
      socket.destroy();
      reject(cause);
    };
    socket.once('connect', () => {
      socket.setTimeout(0);
      resolve(socket);
    });
    socket.once('error', fail);
    socket.setTimeout(timeoutMs, () => fail(new ProtocolError('agent_error', `the build runner at ${path} did not answer`)));
  });
}

function wireClient(socket: Socket, token: string): ControlClient {
  const splitter = new LineSplitter();
  const pending = new Map<number, { resolve: (value: Record<string, unknown>) => void; reject: (cause: Error) => void }>();
  const closers: Array<() => void> = [];
  let onEvent: ((event: RunEvent) => void) | null = null;
  let nextRid = 1;

  const settleAll = (cause: Error): void => {
    for (const waiter of pending.values()) waiter.reject(cause);
    pending.clear();
    for (const fn of closers.splice(0)) fn();
  };

  socket.on('data', (chunk: string) => {
    let lines: string[];
    try {
      lines = splitter.push(chunk);
    } catch (cause) {
      // The channel is desynchronized; nothing further on it can be trusted.
      socket.destroy(cause instanceof Error ? cause : new Error(String(cause)));
      return;
    }
    for (const line of lines) {
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(line) as Record<string, unknown>;
      } catch (cause) {
        socket.destroy(new ProtocolError('agent_error', `the build runner sent an unreadable frame: ${String(cause)}`));
        return;
      }
      if (frame.op === 'event') {
        if (onEvent !== null) onEvent(frame.event as RunEvent);
        continue;
      }
      const waiter = pending.get(frame.rid as number);
      if (waiter === undefined) continue;
      pending.delete(frame.rid as number);
      if (frame.op === 'error') waiter.reject(new ProtocolError('agent_error', String(frame.message)));
      else waiter.resolve(frame);
    }
  });
  socket.on('error', (cause) => settleAll(cause));
  socket.on('close', () => settleAll(new ProtocolError('agent_error', 'the build runner closed the channel')));

  const send = (payload: Record<string, unknown>): Promise<Record<string, unknown>> => {
    const rid = nextRid;
    nextRid += 1;
    return new Promise((resolve, reject) => {
      pending.set(rid, { resolve, reject });
      socket.write(`${JSON.stringify({ ...payload, rid, token })}\n`);
    });
  };

  return {
    attach: async (after, handler) => {
      onEvent = handler;
      const ack = await send({ op: 'attach', after });
      return { replayed: Number(ack.replayed ?? 0), elided: Number(ack.elided ?? 0), seq: Number(ack.seq ?? 0) };
    },
    steer: async (text, from) => {
      await send({ op: 'steer', text, from });
    },
    cancel: async () => {
      await send({ op: 'cancel' });
    },
    ping: async () => {
      const ack = await send({ op: 'ping' });
      return { pid: Number(ack.pid), what: String(ack.what), seq: Number(ack.seq ?? 0) };
    },
    onClose: (fn) => closers.push(fn),
    close: () => socket.destroy(),
  };
}

function messageOf(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}
