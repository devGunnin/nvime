import { closeSync, fstatSync, fsyncSync, openSync, readSync, writeSync } from 'node:fs';
import { ProtocolError } from './protocol.js';

/**
 * The append-only record of a session's detached build: every delta, tool line,
 * phase change, steer and terminal result, one JSON object per line.
 *
 * It is what lets a build outlive the editor that started it. An editor that
 * was not there — a fresh Neovim, a second one attaching mid-run — replays this
 * file and then follows the runner's socket, instead of seeing only the part of
 * the stream it happened to witness. Append-only and never rewritten, so a
 * replay from the same offset always renders the same thing.
 */

/** One recorded event. `event`/`params` are the sidecar's own event shape. */
export interface RunEvent {
  /** 1-based, monotonic within a log, and the cursor an attacher resumes from. */
  seq: number;
  at: number;
  /** The pushed event's name, e.g. `big.delta`. Replayed verbatim. */
  event: string;
  /** The event's payload, WITHOUT a request id — each attacher adds its own. */
  params: Record<string, unknown>;
}

/** What one read of the log yielded, and what it could not reach. */
export interface LogSlice {
  events: RunEvent[];
  /**
   * Events after the cursor this slice does not carry, because the read window
   * begins after them. Estimated from the seq gap, so a line torn by a killed
   * runner counts as elided — which is what it is, from a reader's side.
   */
  elided: number;
}

/** Events that end a run. Nothing is appended to a log after one of these. */
export const TERMINAL_EVENTS: ReadonlySet<string> = new Set(['big.done', 'big.failed']);

/**
 * A whole event line is truncated to this. Not just the delta: a tool summary,
 * a failure detail or a pasted path can be as big, and one enormous line costs
 * every future replay.
 */
export const MAX_EVENT_BYTES = 16 * 1024;

/**
 * Chars of extra slack `bound()` cuts beyond the measured deficit, so a trim
 * pass frees more bytes than the '…' it adds back can ever cost (up to 3 UTF-8
 * bytes) — otherwise a 1-byte-over line stalls forever trimming zero net bytes.
 */
const ELLIPSIS_MARGIN = 4;

/**
 * How much of the log one read carries. The log spans a session's whole life —
 * build, revise, rebase, revise — so an unbounded read would grow without limit
 * and be paid again on every attach, every settle and every handshake poll.
 */
export const MAX_REPLAY_BYTES = 1024 * 1024;

/** Enough tail to hold a whole line, whatever `MAX_EVENT_BYTES` allows. */
const LAST_SEQ_WINDOW_BYTES = 4 * MAX_EVENT_BYTES;

const NEWLINE = 0x0a;

export function isTerminal(event: RunEvent): boolean {
  return TERMINAL_EVENTS.has(event.event);
}

/**
 * The writer. One per runner process: it owns the file descriptor and the
 * sequence counter, and every append is one `writeSync` of one complete line so
 * a reader never has to reassemble a record across writes.
 *
 * A log this cannot read is an error, never an empty one — answering 0 for a
 * log that already holds 1..N would restart numbering over live events.
 */
export class RunLog {
  readonly #path: string;
  #fd: number | null;
  #seq: number;

  constructor(path: string) {
    if (path === '') throw new TypeError('RunLog needs a path');
    // 'a+': appends land at the end whatever the read position, and the tail
    // still has to be read to find the torn line and the sequence to continue.
    const fd = openSync(path, 'a+');
    try {
      terminateTornTail(fd, path);
      // Continues the session's history rather than restarting it: a second run
      // on the same session (a resume, a revision) appends to the same log, and
      // a seq that went backwards would make an attacher skip the new events.
      this.#seq = lastSeqOf(path);
    } catch (cause) {
      closeSync(fd);
      throw cause;
    }
    this.#fd = fd;
    this.#path = path;
  }

  get path(): string {
    return this.#path;
  }

  /** The last seq written. An attacher resuming from it sees only what follows. */
  get seq(): number {
    return this.#seq;
  }

  /** This log's own events after `after` — what an attaching viewer replays. */
  readAfter(after: number): LogSlice {
    return readLogAfter(this.#path, after);
  }

  /**
   * Appends one event and returns it as recorded — bounded, so what a viewer
   * gets live is what a replay will give it. Throws when the log is closed or
   * takes only part of the line: an event that cannot be recorded must not be
   * silently dropped, because the record is all a detached run has to show.
   */
  append(event: string, params: Record<string, unknown>): RunEvent {
    const fd = this.#fd;
    if (fd === null) throw new Error(`the run log ${this.#path} is closed`);
    this.#seq += 1;
    const record = bound({ seq: this.#seq, at: Date.now(), event, params });
    const line = Buffer.from(`${JSON.stringify(record)}\n`, 'utf8');
    const written = writeSync(fd, line);
    if (written !== line.length) {
      // A short write leaves a torn tail, and every later append would land on
      // those bytes. Stop writing rather than pile onto them.
      this.#fd = null;
      closeSync(fd);
      throw new Error(`the run log ${this.#path} took ${written} of ${line.length} bytes — out of space?`);
    }
    // The one record that says a finished build finished: worth the flush.
    if (isTerminal(record)) fsyncSync(fd);
    return record;
  }

  close(): void {
    const fd = this.#fd;
    if (fd === null) return;
    this.#fd = null;
    closeSync(fd);
  }
}

/**
 * Every event after `after` that the last `maxBytes` of the log hold, in order.
 * A line that does not parse is skipped loudly: an append-only log's last line
 * can be torn by a killed runner, and refusing to render the whole build over
 * it would help nobody.
 *
 * @throws ProtocolError when the log exists but cannot be read. An absent log
 *   is empty — a session nobody has built yet — but an unreadable one is not.
 */
export function readLogAfter(path: string, after: number, maxBytes = MAX_REPLAY_BYTES): LogSlice {
  if (!Number.isInteger(after) || after < 0) throw new TypeError('readLogAfter needs a seq >= 0');
  if (!Number.isInteger(maxBytes) || maxBytes <= 0) throw new TypeError('readLogAfter needs a positive window');
  const tail = readTail(path, maxBytes);
  if (tail === null) return { events: [], elided: 0 };
  const events: RunEvent[] = [];
  for (const line of tail.text.split('\n')) {
    if (line === '') continue;
    const event = parseEvent(line, path);
    if (event !== null && event.seq > after) events.push(event);
  }
  const first = events[0];
  if (!tail.windowed || first === undefined) return { events, elided: 0 };
  return { events, elided: Math.max(0, first.seq - after - 1) };
}

/**
 * The highest seq the log already holds, or 0 for a log that is not there.
 *
 * @throws ProtocolError when the log exists but cannot be read.
 */
export function lastSeqOf(path: string): number {
  const { events } = readLogAfter(path, 0, LAST_SEQ_WINDOW_BYTES);
  return events[events.length - 1]?.seq ?? 0;
}

/**
 * The last `maxBytes` of the file as whole lines. A window that starts
 * mid-line drops that first partial line — it belongs to the part not read.
 *
 * A window that contains no newline at all (one line wider than `maxBytes`)
 * cannot be trusted to mean "nothing here" — widening all the way to the
 * start of the file is the only way to tell "empty" from "one huge line".
 */
function readTail(path: string, maxBytes: number): { text: string; windowed: boolean } | null {
  let fd: number;
  try {
    fd = openSync(path, 'r');
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return null;
    throw new ProtocolError('agent_error', `cannot open the build log ${path}`, String(cause));
  }
  try {
    const size = fstatSync(fd).size;
    return readWindow(fd, size, maxBytes);
  } catch (cause) {
    if (cause instanceof ProtocolError) throw cause;
    throw new ProtocolError('agent_error', `cannot read the build log ${path}`, String(cause));
  } finally {
    closeSync(fd);
  }
}

function readWindow(fd: number, size: number, maxBytes: number): { text: string; windowed: boolean } {
  const from = Math.max(0, size - maxBytes);
  const buffer = Buffer.allocUnsafe(size - from);
  const got = readInto(fd, buffer, from);
  const text = buffer.subarray(0, got).toString('utf8');
  if (from === 0) return { text, windowed: false };
  const newline = text.indexOf('\n');
  const rest = newline === -1 ? '' : text.slice(newline + 1);
  // `rest` is empty both when the window holds no newline at all, and when
  // its only newline terminates the one partial line the window started
  // mid-way through — either way, zero complete lines were captured.
  if (rest === '') return readWindow(fd, size, size);
  return { text: rest, windowed: true };
}

/** Fills `buffer` from `position`, and answers how much the file actually had. */
function readInto(fd: number, buffer: Buffer, position: number): number {
  let got = 0;
  while (got < buffer.length) {
    const chunk = readSync(fd, buffer, got, buffer.length - got, position + got);
    if (chunk === 0) break;
    got += chunk;
  }
  return got;
}

/**
 * Terminates a last line that has no newline — a runner killed mid-write, or a
 * short write. Without it the next append lands on those bytes and is swallowed
 * along with them.
 */
function terminateTornTail(fd: number, path: string): void {
  const size = fstatSync(fd).size;
  if (size === 0) return;
  const last = Buffer.allocUnsafe(1);
  if (readSync(fd, last, 0, 1, size - 1) !== 1) {
    throw new ProtocolError('agent_error', `cannot read the tail of the build log ${path}`);
  }
  if (last[0] === NEWLINE) return;
  process.stderr.write(`nvime: the build log ${path} ended mid-line; terminating it before appending\n`);
  writeSync(fd, '\n');
}

function parseEvent(line: string, path: string): RunEvent | null {
  try {
    const raw = JSON.parse(line) as RunEvent;
    if (typeof raw.seq !== 'number' || !Number.isInteger(raw.seq) || raw.seq < 1) throw new Error('bad seq');
    if (typeof raw.event !== 'string' || raw.event === '') throw new Error('bad event name');
    if (typeof raw.params !== 'object' || raw.params === null) throw new Error('bad params');
    return raw;
  } catch (cause) {
    process.stderr.write(`nvime: skipping an unreadable line in ${path}: ${String(cause)}\n`);
    return null;
  }
}

/**
 * The record with its string fields cut down until the whole line fits. Every
 * one of them is fair game — the invariant is the line's size, not one field's.
 *
 * Measured rather than computed: a character can cost four bytes in UTF-8 and
 * six more once JSON escapes it, so arithmetic on the raw length is an upper
 * bound, not an answer.
 */
function bound(record: RunEvent): RunEvent {
  if (lineBytes(record) <= MAX_EVENT_BYTES) return record;
  const params: Record<string, unknown> = { ...record.params, truncated: true };
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const trimmed: RunEvent = { ...record, params };
    const size = lineBytes(trimmed);
    if (size <= MAX_EVENT_BYTES) return trimmed;
    const key = longestStringKey(params);
    if (key === null) break;
    const value = params[key] as string;
    // The ellipsis itself costs up to 3 UTF-8 bytes, and a cut character can
    // free as little as 1 — so cutting exactly the deficit can leave the line
    // the same size or bigger and never converge. ELLIPSIS_MARGIN chars of
    // slack guarantees every pass frees more bytes than the ellipsis costs.
    const overBy = Math.max(size - MAX_EVENT_BYTES, 1);
    const keep = Math.max(value.length - overBy - ELLIPSIS_MARGIN, 0);
    params[key] = keep === 0 ? '…' : `${value.slice(0, keep)}…`;
  }
  // Nothing string-shaped left to cut. Keep the event's identity — a terminal
  // event must stay terminal — and say plainly that its body is gone.
  return { ...record, params: { truncated: true, elided: `the ${record.event} payload was too large to record` } };
}

function lineBytes(record: RunEvent): number {
  return Buffer.byteLength(JSON.stringify(record), 'utf8') + 1;
}

/** The param carrying the longest string, or null when none is left to cut. */
function longestStringKey(params: Record<string, unknown>): string | null {
  let best: string | null = null;
  let longest = 1;
  for (const [key, value] of Object.entries(params)) {
    if (typeof value === 'string' && value.length > longest) {
      best = key;
      longest = value.length;
    }
  }
  return best;
}
