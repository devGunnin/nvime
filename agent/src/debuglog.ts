import { appendFileSync, chmodSync, statSync } from 'node:fs';
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

/**
 * Substrings that make a field name secret wherever they appear in it.
 * `socket` is here because the runner's control socket plus its token are a
 * live channel into a running build.
 */
const SECRET_PARTS = ['token', 'secret', 'password', 'passwd', 'authorization', 'credential', 'socket'];

/**
 * DENY BY DEFAULT. A string is written out only under a name on this list;
 * every other string is recorded as its size. Four rounds of enumerating what
 * to HIDE each ended one name short of the payload, so the question is
 * inverted: not "is this field dangerous" but "has this name been vouched
 * for". Kept in step with `lua/nvime/log.lua`'s list, which is the same rule
 * on the other half of the same file.
 *
 * Every entry also needs a producer that vouches for it — a name nothing
 * produces is a free pass for whatever gets it next. Refused after checking
 * the producers: `reason` (the policy layer builds it as prose around an error
 * message and a path), `origin` (a steer's label is whatever the peer sent;
 * `runsock` only ever renders it), `model` (typed at `:Nvime model`), and
 * `outcome` (nothing emits it).
 */
export const SAFE_KEYS: readonly string[] = [
  // Identifiers. Correlating a stuck run is the whole point of the log.
  'id',
  'sessionId',
  'blockId',
  'approvalId',
  'runId',
  'diffId',
  'policyId',
  'session',
  'target',
  'seq',
  // nvime's own vocabulary: closed sets, all defined in this codebase.
  'state',
  'display',
  'phase',
  'kind',
  'type',
  'method',
  'event',
  'level',
  'code',
  'cause',
  'difficulty',
  'effort',
  'op',
  // The tool's NAME, never its arguments or its summary.
  'tool',
  // Version strings are the vendor's; a model id is NOT here, because
  // `:Nvime model` has the reader type one by hand.
  'version',
  // Object names: hex, and nothing else.
  'sha',
  'commit',
  'base_sha',
  'head_sha',
  // Filesystem paths — but NOT `entries`, which is a listing of a directory
  // the reader chose to attach, i.e. their disk rather than this project.
  'file',
  'files',
  'path',
  'dir',
  'root',
  'worktree',
  // A line range nvime built, e.g. `10-24`.
  'range',
  // Transitions, named for what they hold so the pair cannot later take prose.
  'from_display',
  'to_display',
  'from_session',
  'to_session',
];

const SAFE = new Set(SAFE_KEYS);

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

/** Lists that carry nothing the reader could have written. */
function allScalar(list: unknown[]): boolean {
  return list.every((element) => typeof element === 'number' || typeof element === 'boolean');
}

/**
 * The rule, in full:
 *   secret-named  → `<redacted>`, whatever the type. Always wins.
 *   number/bool   → through, whatever it is called.
 *   object        → recurse; each leaf answers for its OWN name.
 *   list          → through only under a safe name AND only if every element
 *                   is a number or a boolean; otherwise `<N items>`.
 *   string        → through only under a safe name; otherwise `<N chars>`.
 * The clip still bounds the line, but is never the reason something is safe.
 */
function redact(value: unknown, key: string | null, depth: number): unknown {
  if (key !== null && isSecretKey(key)) return REDACTED;
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'string') return key !== null && SAFE.has(key) ? value : summarise(value);
  if (value === null || typeof value !== 'object') return summarise(value);
  if (depth >= MAX_DEPTH) return '<deep>';
  if (Array.isArray(value)) {
    return key !== null && SAFE.has(key) && allScalar(value) ? value : summarise(value);
  }
  const out: Record<string, unknown> = {};
  for (const [name, nested] of Object.entries(value)) out[name] = redact(nested, name, depth + 1);
  return out;
}

/** One payload as a single redacted, clipped line. */
export function renderParams(params: unknown): string {
  if (params === undefined) return '';
  let encoded: string;
  try {
    encoded = JSON.stringify(redact(params, null, 0)) ?? '';
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
  /** Set once this level's file has been chmodded, so it is done once. */
  #tightened = false;

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
    this.#tightened = false;
    this.#bytes = level === 'off' || path === null ? 0 : sizeOf(path);
    if (level === 'off' || path === null) return;
    // One trial line, so a mirror that cannot write is a refusal the plugin
    // sees now. Latching on stderr instead left `debug.set` answering ok while
    // half the "one timeline" quietly went missing. Deliberately past the cap
    // check: a full log must read as full, never as broken.
    this.#append(path, `${new Date().toISOString()} agent note  mirror on at ${level}\n`);
    if (this.#broken) {
      this.#level = 'off';
      this.#path = null;
      throw new ProtocolError('agent_error', `the debug log ${path} could not be written`);
    }
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
      appendFileSync(path, record, 'utf8');
      // Owner-only on the first append of a session, whether this half created
      // the file or found it: a file left 0644 by anything else is still ours
      // to tighten, and the log carries project paths and session ids.
      if (!this.#tightened) {
        chmodSync(path, 0o600);
        this.#tightened = true;
      }
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
