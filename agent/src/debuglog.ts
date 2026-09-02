import { appendFileSync, chmodSync, existsSync, statSync } from 'node:fs';
import { ProtocolError } from './protocol.js';

/**
 * The sidecar's half of the plugin's debug log.
 *
 * The plugin owns the file — where it lives, when it rotates, whether it
 * exists at all — and turns this half on with `debug.set` so both halves of a
 * stuck run land in one timeline. Off by default and free when off: nothing is
 * formatted, nothing is opened, no file is created.
 *
 * The same redaction the plugin applies is applied here, and for the same
 * reason: the file exists to be pasted into a public issue, so a prompt, a
 * file's contents or a token-shaped setting must never be able to reach it.
 */

export type DebugLevel = 'off' | 'info' | 'debug';

const LEVELS: readonly DebugLevel[] = ['off', 'info', 'debug'];
const ORDER: Record<DebugLevel, number> = { off: 0, info: 1, debug: 2 };

export const REDACTED = '<redacted>';

/**
 * How much of one payload a line may carry. UTF-16 code units here, bytes in
 * `lua/nvime/log.lua` — the same number, not the same unit, and neither half
 * splits a character: this one cuts on a code-unit boundary and steps back off
 * a lone surrogate.
 */
export const MAX_PAYLOAD_CHARS = 200;

/**
 * The plugin rotates at 5 MB. This half never rotates — two writers renaming
 * one file race — so it stops at the same mark and lets the plugin's next
 * write rotate. `#bytes` is a cheap running estimate of the FILE's size, not
 * of this process's own writes: it is re-stat'd whenever the estimate says the
 * cap is reached, so a rotation underneath brings the mirror straight back.
 */
export const MAX_BYTES = 5 * 1024 * 1024;

/** Substrings that make a field name secret wherever they appear in it. */
const SECRET_PARTS = ['token', 'secret', 'password', 'passwd', 'authorization', 'credential'];

/**
 * Fields carrying what the user wrote or what their files hold. Recorded as a
 * size, never as text.
 */
const CONTENT_KEYS = new Set([
  'answers',
  'comment',
  'content',
  'context',
  'diff',
  'message',
  'prompt',
  'rationale',
  'spec',
  'summary',
  'text',
  'title',
]);

/** How deep redaction walks before it stops describing and starts eliding. */
const MAX_DEPTH = 8;

export function isDebugLevel(value: unknown): value is DebugLevel {
  return typeof value === 'string' && (LEVELS as readonly string[]).includes(value);
}

export function isSecretKey(name: string): boolean {
  const lower = name.toLowerCase();
  if (SECRET_PARTS.some((part) => lower.includes(part))) return true;
  // `key` only as a whole word or a suffix: `keymaps` is not a secret.
  return lower === 'key' || lower === 'apikey' || /(?:[_-]key|api_?key)$/.test(lower);
}

function summarise(value: unknown): string {
  if (typeof value === 'string') return `<${value.length} chars>`;
  if (Array.isArray(value)) return `<${value.length} items>`;
  return `<${typeof value}>`;
}

/**
 * A content-named field only carries content when it is text or a list of it.
 * `context` is a block list in an RPC payload and a settings object in the
 * config the bundle renders; summarising the settings object would gut it.
 */
function isContent(value: unknown): boolean {
  return typeof value === 'string' || Array.isArray(value);
}

function redact(value: unknown, depth: number): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (depth >= MAX_DEPTH) return '<deep>';
  if (Array.isArray(value)) return value.map((entry) => redact(entry, depth + 1));
  const out: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(value)) {
    if (isSecretKey(key)) out[key] = REDACTED;
    else if (CONTENT_KEYS.has(key) && isContent(nested)) out[key] = summarise(nested);
    else out[key] = redact(nested, depth + 1);
  }
  return out;
}

/** One payload as a single redacted, clipped line. */
export function renderParams(params: unknown): string {
  if (params === undefined) return '';
  let encoded: string;
  try {
    encoded = JSON.stringify(redact(params, 0)) ?? '';
  } catch {
    encoded = '<unencodable payload>';
  }
  if (encoded.length <= MAX_PAYLOAD_CHARS) return encoded;
  // Back off a lone high surrogate, or the cut writes half a character.
  const at = isHighSurrogate(encoded.charCodeAt(MAX_PAYLOAD_CHARS - 1))
    ? MAX_PAYLOAD_CHARS - 1
    : MAX_PAYLOAD_CHARS;
  return `${encoded.slice(0, at)}…(clipped)`;
}

function isHighSurrogate(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

export class DebugLog {
  #level: DebugLevel = 'off';
  #path: string | null = null;
  /** Bytes believed to be in the file, so the cap costs one stat per level change. */
  #bytes = 0;
  /** Set once a write failed, so a broken log complains once, not per frame. */
  #broken = false;
  /** Set once the cap notice has been written, so it is written only once. */
  #atCap = false;

  get level(): DebugLevel {
    return this.#level;
  }

  get path(): string | null {
    return this.#path;
  }

  /**
   * Points this half at the plugin's log file, or turns it off. An unknown
   * level is a `bad_request`, never a silent downgrade — a plugin that thinks
   * it turned logging on and got nothing has a worse bug to chase.
   */
  setLevel(level: DebugLevel, path: string | null): void {
    if (!isDebugLevel(level)) {
      throw new ProtocolError('bad_request', `params.level must be one of: ${LEVELS.join(', ')}`);
    }
    if (level !== 'off' && (path === null || path === '')) {
      throw new ProtocolError('bad_request', 'params.path is required to turn the debug log on');
    }
    this.#level = level;
    this.#path = path;
    this.#broken = false;
    this.#atCap = false;
    this.#bytes = level === 'off' || path === null ? 0 : sizeOf(path);
  }

  /** Whether a line at `level` would be written. Checked BEFORE the caller
   *  builds its line: at `off` a streamed token must cost nothing at all. */
  enabled(level: DebugLevel): boolean {
    return ORDER[this.#level] >= ORDER[level];
  }

  /** One request this sidecar accepted. */
  request(method: string, id: number, params: unknown): void {
    if (!this.enabled('info')) return;
    this.#write(`rpc handled ${method} #${id} ${renderParams(params)}`);
  }

  /** How that request ended, and how long it took. */
  reply(method: string, id: number, durationMs: number, errorCode?: string): void {
    if (!this.enabled('info')) return;
    const outcome = errorCode === undefined ? 'ok' : `error ${errorCode}`;
    this.#write(`rpc answered ${method} #${id} ${durationMs}ms ${outcome}`);
  }

  /** Anything else worth a line in the shared timeline. */
  note(text: string): void {
    if (!this.enabled('info')) return;
    this.#write(`note  ${text}`);
  }

  /** A line only a `debug` level wants — the chatty per-frame detail. */
  detail(text: string): void {
    if (!this.enabled('debug')) return;
    this.#write(`detail ${text}`);
  }

  /**
   * Writes one already-formatted line. The LEVEL IS NOT CHECKED HERE — every
   * caller checks it before building the line, which is what makes `off` free.
   */
  #write(line: string): void {
    const path = this.#path;
    if (path === null || this.#broken) return;
    const record = `${new Date().toISOString()} agent ${line}\n`;
    if (this.#bytes + record.length > MAX_BYTES && !this.#recheckCap(path, record.length)) return;
    this.#append(path, record);
  }

  /**
   * The estimate says the file is full. Ask the filesystem instead: the plugin
   * may have rotated underneath, in which case the mirror resumes. If it
   * really is full, say so once — a mirror that just stops leaves half the
   * timeline missing with nothing to explain it.
   *
   * @returns whether there is room for a record of `length` bytes
   */
  #recheckCap(path: string, length: number): boolean {
    this.#bytes = sizeOf(path);
    if (this.#bytes + length <= MAX_BYTES) {
      this.#atCap = false;
      return true;
    }
    if (!this.#atCap) {
      this.#atCap = true;
      this.#append(path, `${new Date().toISOString()} agent note  mirror stopped: log at cap\n`);
    }
    return false;
  }

  #append(path: string, record: string): void {
    try {
      const fresh = !existsSync(path);
      appendFileSync(path, record, 'utf8');
      // Owner-only, before anything but the first line: the shared log carries
      // project paths and session ids.
      if (fresh) chmodSync(path, 0o600);
      this.#bytes += record.length;
    } catch (cause) {
      this.#broken = true;
      process.stderr.write(`nvime: could not write the debug log ${path}: ${String(cause)}\n`);
    }
  }
}

function sizeOf(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}
