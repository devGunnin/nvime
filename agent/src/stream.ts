import { homedir } from 'node:os';
import { relative, sep } from 'node:path';

/**
 * Reading the SDK's message stream: the shapes chat and edit both consume.
 * Kept in one place so the two capabilities cannot drift into rendering the
 * same frame differently.
 */

export interface RunUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

export function readUsage(usage: unknown): RunUsage {
  const u = (usage ?? {}) as Record<string, unknown>;
  const n = (key: string): number => (typeof u[key] === 'number' ? (u[key] as number) : 0);
  return {
    input: n('input_tokens'),
    output: n('output_tokens'),
    cacheRead: n('cache_read_input_tokens'),
    cacheCreation: n('cache_creation_input_tokens'),
  };
}

/** Text of a `content_block_delta` stream event, or null for every other event. */
export function textDelta(event: unknown): string | null {
  const e = event as { type?: string; delta?: { type?: string; text?: string } } | null;
  if (e === null || e.type !== 'content_block_delta') return null;
  if (e.delta?.type !== 'text_delta' || typeof e.delta.text !== 'string') return null;
  return e.delta.text;
}

export interface ToolCall {
  id: string;
  tool: string;
  summary: string;
}

/** One dim status line per tool call in an assistant message, in call order. */
export function toolCalls(message: unknown, cwd: string): ToolCall[] {
  const content = (message as { content?: unknown } | null)?.content;
  if (!Array.isArray(content)) return [];
  const out: ToolCall[] = [];
  for (const block of content) {
    const b = block as { type?: string; id?: string; name?: string; input?: Record<string, unknown> };
    if (b.type !== 'tool_use' || typeof b.name !== 'string') continue;
    out.push({
      id: typeof b.id === 'string' ? b.id : '',
      tool: b.name,
      summary: describeTool(b.name, b.input ?? {}, cwd),
    });
  }
  return out;
}

/** Ids of the tool calls a user message carries results for, in arrival order. */
export function toolResultIds(message: unknown): string[] {
  const content = (message as { content?: unknown } | null)?.content;
  if (!Array.isArray(content)) return [];
  const out: string[] = [];
  for (const block of content) {
    const b = block as { type?: string; tool_use_id?: string };
    if (b.type === 'tool_result' && typeof b.tool_use_id === 'string' && b.tool_use_id !== '') {
      out.push(b.tool_use_id);
    }
  }
  return out;
}

/**
 * Ceiling on the verbatim payload sent with an approval. Generous enough that
 * no real command or path reaches it, small enough that one frame cannot pin
 * the editor. Past it the payload is marked `truncated` and the float says so.
 */
export const MAX_DETAIL_BYTES = 8 * 1024;

/** The thing the user is actually being asked to authorize, verbatim. */
export interface ToolDetail {
  /** What it is, in the words the float labels it with: `command`, `path`, `url`. */
  kind: string;
  /** The value itself. Never whitespace-collapsed and never elided mid-string. */
  text: string;
  truncated: boolean;
  /** Byte length of the WHOLE value, so the float can say how much is missing. */
  bytes: number;
}

const DETAIL_KEYS: Readonly<Record<string, { kind: string; key: string }>> = {
  Bash: { kind: 'command', key: 'command' },
  Edit: { kind: 'path', key: 'file_path' },
  Write: { kind: 'path', key: 'file_path' },
  NotebookEdit: { kind: 'path', key: 'notebook_path' },
  WebFetch: { kind: 'url', key: 'url' },
};

/**
 * The verbatim payload for an approval frame, or null for a tool that asks the
 * user to authorize nothing in particular.
 *
 * `describeTool`'s one-line summary is for the panel's status feed and clips
 * hard; a truncated command is not something a human can consent to, so the
 * approval carries this instead and the float renders every byte of it.
 */
export function toolDetail(name: string, input: Record<string, unknown>): ToolDetail | null {
  const spec = DETAIL_KEYS[name];
  if (spec === undefined) return null;
  const value = input[spec.key];
  if (typeof value !== 'string' || value === '') return null;
  const buffer = Buffer.from(value, 'utf8');
  if (buffer.length <= MAX_DETAIL_BYTES) {
    return { kind: spec.kind, text: value, truncated: false, bytes: buffer.length };
  }
  // Back off to a code-point boundary: UTF-8 continuation bytes are 10xxxxxx,
  // and cutting one in half would put a replacement character on screen.
  let end = MAX_DETAIL_BYTES;
  while (end > 0 && ((buffer[end] ?? 0) & 0xc0) === 0x80) end -= 1;
  return {
    kind: spec.kind,
    text: buffer.subarray(0, end).toString('utf8'),
    truncated: true,
    bytes: buffer.length,
  };
}

const MAX_SUMMARY_CHARS = 120;

function clip(text: string): string {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  return oneLine.length <= MAX_SUMMARY_CHARS ? oneLine : oneLine.slice(0, MAX_SUMMARY_CHARS - 1) + '…';
}

/**
 * How one path is written in a status line: relative to the project when it is
 * inside it, otherwise where it really is, with the home directory as `~`.
 *
 * `relative` answers for anything outside the root with a ladder of `..`
 * segments that says nothing about where the file actually is.
 */
export function shortPath(value: string, cwd: string): string {
  const inside = relative(cwd, value);
  if (inside !== '' && !inside.startsWith('..')) return inside;
  const home = homedir();
  if (home !== '' && (value === home || value.startsWith(home + sep))) {
    return '~' + value.slice(home.length);
  }
  return value;
}

export function describeTool(name: string, input: Record<string, unknown>, cwd: string): string {
  const text = (key: string): string | null =>
    typeof input[key] === 'string' && input[key] !== '' ? (input[key] as string) : null;
  const forPath = (key: string, verb: string, fallback: string): string => {
    const path = text(key);
    return path === null ? fallback : `${verb} ${shortPath(path, cwd)}`;
  };
  switch (name) {
    case 'Read':
      return forPath('file_path', 'reading', 'reading a file');
    case 'Edit':
      return forPath('file_path', 'editing', 'editing a file');
    case 'Write':
      return forPath('file_path', 'writing', 'writing a file');
    case 'NotebookEdit':
      return forPath('notebook_path', 'editing', 'editing a notebook');
    case 'Bash': {
      const command = text('command');
      return command === null ? 'running a shell command' : `running ${clip(command)}`;
    }
    case 'Glob': {
      const pattern = text('pattern');
      return pattern === null ? 'listing files' : `globbing ${pattern}`;
    }
    case 'Grep': {
      const pattern = text('pattern');
      return pattern === null ? 'searching' : `searching for ${pattern}`;
    }
    case 'WebFetch': {
      const url = text('url');
      return url === null ? 'fetching a page' : `fetching ${url}`;
    }
    case 'WebSearch': {
      const q = text('query');
      return q === null ? 'searching the web' : `searching the web for ${q}`;
    }
    default:
      return `using ${name}`;
  }
}
