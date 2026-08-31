import { relative } from 'node:path';

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

const MAX_SUMMARY_CHARS = 120;

function clip(text: string): string {
  const oneLine = text.replace(/\s+/g, ' ').trim();
  return oneLine.length <= MAX_SUMMARY_CHARS ? oneLine : oneLine.slice(0, MAX_SUMMARY_CHARS - 1) + '…';
}

export function describeTool(name: string, input: Record<string, unknown>, cwd: string): string {
  const text = (key: string): string | null =>
    typeof input[key] === 'string' && input[key] !== '' ? (input[key] as string) : null;
  const shortPath = (value: string): string => relative(cwd, value) || value;
  const forPath = (key: string, verb: string, fallback: string): string => {
    const path = text(key);
    return path === null ? fallback : `${verb} ${shortPath(path)}`;
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
