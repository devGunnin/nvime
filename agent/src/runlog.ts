import { closeSync, openSync, readFileSync, writeSync } from 'node:fs';

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

/** Events that end a run. Nothing is appended to a log after one of these. */
export const TERMINAL_EVENTS: ReadonlySet<string> = new Set(['big.done', 'big.failed']);

/**
 * A line longer than this is truncated rather than written. Deltas are the only
 * unbounded field, and one enormous line would cost every future replay.
 */
export const MAX_EVENT_BYTES = 16 * 1024;

export function isTerminal(event: RunEvent): boolean {
  return TERMINAL_EVENTS.has(event.event);
}

/**
 * The writer. One per runner process: it owns the file descriptor and the
 * sequence counter, and every append is one `writeSync` of one complete line so
 * a reader never has to reassemble a record across writes.
 */
export class RunLog {
  readonly #path: string;
  #fd: number | null;
  #seq: number;

  constructor(path: string) {
    if (path === '') throw new TypeError('RunLog needs a path');
    // Continues the session's history rather than restarting it: a second run
    // on the same session (a resume, a revision) appends to the same log, and
    // a seq that went backwards would make an attacher skip the new events.
    this.#seq = lastSeqOf(path);
    this.#fd = openSync(path, 'a');
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
  readAfter(after: number): RunEvent[] {
    return readEventsAfter(this.#path, after);
  }

  /**
   * Appends one event and returns it. Throws when the log is closed — an event
   * that cannot be recorded must not be silently dropped, because the record is
   * the only thing a detached run has to show for itself.
   */
  append(event: string, params: Record<string, unknown>): RunEvent {
    const fd = this.#fd;
    if (fd === null) throw new Error(`the run log ${this.#path} is closed`);
    this.#seq += 1;
    const record: RunEvent = { seq: this.#seq, at: Date.now(), event, params };
    writeSync(fd, `${JSON.stringify(bound(record))}\n`);
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
 * Every event after `after`, in order. A line that does not parse is skipped
 * loudly: an append-only log's last line can be torn by a killed runner, and
 * refusing to render the whole build over it would help nobody.
 */
export function readEventsAfter(path: string, after: number): RunEvent[] {
  if (!Number.isInteger(after) || after < 0) throw new TypeError('readEventsAfter needs a seq >= 0');
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') {
      process.stderr.write(`nvime: cannot read the build log ${path}: ${String(cause)}\n`);
    }
    return [];
  }
  const events: RunEvent[] = [];
  for (const line of text.split('\n')) {
    if (line === '') continue;
    const event = parseEvent(line, path);
    if (event !== null && event.seq > after) events.push(event);
  }
  return events;
}

/** The highest seq the log already holds, or 0 for a log that is not there. */
export function lastSeqOf(path: string): number {
  const events = readEventsAfter(path, 0);
  const last = events[events.length - 1];
  return last === undefined ? 0 : last.seq;
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
 * The record, with its longest string field cut down until the whole line fits.
 * Only `text` is ever long enough to matter, so it is the only one trimmed; a
 * record that is still too big without it is written as-is rather than mangled.
 *
 * Measured rather than computed: a character can cost four bytes in UTF-8 and
 * six more once JSON escapes it, so a length arithmetic on the raw string is
 * an upper bound, not an answer.
 */
function bound(record: RunEvent): RunEvent {
  if (Buffer.byteLength(JSON.stringify(record), 'utf8') <= MAX_EVENT_BYTES) return record;
  const text = record.params.text;
  if (typeof text !== 'string') return record;
  const shape = (kept: string): RunEvent => ({
    ...record,
    params: { ...record.params, text: `${kept}…`, truncated: true },
  });
  let kept = text;
  for (let attempt = 0; attempt < 24 && kept !== ''; attempt += 1) {
    const size = Buffer.byteLength(JSON.stringify(shape(kept)), 'utf8');
    if (size <= MAX_EVENT_BYTES) return shape(kept);
    // Each round drops at least as many characters as the line has bytes to
    // spare, so this converges in a handful of passes on any input.
    kept = kept.slice(0, Math.max(kept.length - (size - MAX_EVENT_BYTES), 0));
  }
  return shape('');
}
