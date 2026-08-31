import { relative } from 'node:path';
import type {
  GetSessionMessagesOptions,
  ListSessionsOptions,
  Options,
  SDKMessage,
  SDKSessionInfo,
  SessionMessage,
} from '@anthropic-ai/claude-agent-sdk';
import { composePrompt, type ContextBlock } from './context.js';
import { subscriptionEnv, type Env } from './env.js';
import { ProtocolError } from './protocol.js';
import { SessionStore } from './sessions.js';

/**
 * Chat is read-only by construction: the model gets research tools and nothing
 * that can change the tree. Enforced through SDK options, never prompt text.
 */
export const CHAT_TOOLS = ['Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch'] as const;
export const CHAT_DENIED_TOOLS = [
  'Bash',
  'BashOutput',
  'KillShell',
  'Edit',
  'Write',
  'NotebookEdit',
  'Task',
  'Agent',
  'SlashCommand',
] as const;

/** Seam for P2/P3: `edit.*` and `big.*` build their own options here. */

export interface SdkBindings {
  query: (params: { prompt: string; options?: Options }) => AsyncIterable<SDKMessage>;
  listSessions: (options?: ListSessionsOptions) => Promise<SDKSessionInfo[]>;
  getSessionMessages: (
    sessionId: string,
    options?: GetSessionMessagesOptions,
  ) => Promise<SessionMessage[]>;
}

export type EmitEvent = (event: string, params: Record<string, unknown>) => void;

export interface SendParams {
  root: string;
  prompt: string;
  context: ContextBlock[];
  sessionId?: string | undefined;
}

export interface ChatDone {
  sessionId: string;
  text: string;
  numTurns: number;
  usage: { input: number; output: number; cacheRead: number; cacheCreation: number };
  costUsd: number;
}

export interface SessionSummary {
  sessionId: string;
  title: string;
  lastModified: number;
}

export interface ChatServiceOptions {
  sdk: SdkBindings;
  store: SessionStore;
  claudePath: string;
  env: Env;
  emit: EmitEvent;
  model?: string | undefined;
}

export class ChatService {
  readonly #sdk: SdkBindings;
  readonly #store: SessionStore;
  readonly #claudePath: string;
  readonly #env: Env;
  readonly #emit: EmitEvent;
  readonly #model: string | undefined;
  /** Request id -> abort handle, and project root -> request id, for cancel and busy checks. */
  readonly #running = new Map<number, AbortController>();
  readonly #runningByRoot = new Map<string, number>();
  #authOk: boolean | null = null;

  constructor(options: ChatServiceOptions) {
    this.#sdk = options.sdk;
    this.#store = options.store;
    this.#claudePath = options.claudePath;
    this.#env = subscriptionEnv(options.env);
    this.#emit = options.emit;
    this.#model = options.model;
  }

  /** null until a turn has actually proved (or disproved) the local login. */
  get authOk(): boolean | null {
    return this.#authOk;
  }

  get activeRuns(): number {
    return this.#running.size;
  }

  async send(requestId: number, params: SendParams): Promise<ChatDone> {
    if (this.#runningByRoot.has(params.root)) {
      throw new ProtocolError('busy', 'a chat run is already in flight for this project');
    }
    const resume = params.sessionId ?? this.#store.get(params.root).current ?? undefined;
    const abort = new AbortController();
    this.#running.set(requestId, abort);
    this.#runningByRoot.set(params.root, requestId);
    try {
      return await this.#run(requestId, params, resume, abort);
    } finally {
      this.#running.delete(requestId);
      this.#runningByRoot.delete(params.root);
    }
  }

  /** True when a run was cancelled; false when there was nothing to cancel. */
  cancel(requestId: number): boolean {
    const abort = this.#running.get(requestId);
    if (abort === undefined) return false;
    abort.abort();
    return true;
  }

  async list(root: string, limit: number): Promise<{ current: string | null; sessions: SessionSummary[] }> {
    const live = await this.#sdk.listSessions({ dir: root, limit: 200 });
    const byId = new Map(live.map((info) => [info.sessionId, info]));
    this.#store.retain(root, new Set(byId.keys()));
    const entry = this.#store.get(root);
    const sessions = entry.known
      .map((id) => byId.get(id))
      .filter((info): info is SDKSessionInfo => info !== undefined)
      .slice(0, limit)
      .map(toSummary);
    return { current: entry.current, sessions };
  }

  async history(root: string, sessionId: string, limit: number): Promise<
    Array<{ role: 'user' | 'assistant'; text: string }>
  > {
    const messages = await this.#sdk.getSessionMessages(sessionId, { dir: root, limit });
    const turns: Array<{ role: 'user' | 'assistant'; text: string }> = [];
    for (const message of messages) {
      if (message.type !== 'user' && message.type !== 'assistant') continue;
      const text = extractText(message.message);
      if (text !== '') turns.push({ role: message.type, text });
    }
    return turns;
  }

  async #run(
    requestId: number,
    params: SendParams,
    resume: string | undefined,
    abort: AbortController,
  ): Promise<ChatDone> {
    const options = this.#buildOptions(params.root, resume, abort);
    const prompt = composePrompt(params.prompt, params.context, params.root);
    let sessionId = resume ?? '';

    try {
      for await (const message of this.#sdk.query({ prompt, options })) {
        if (message.type === 'system' && message.subtype === 'init') {
          sessionId = message.session_id;
          this.#emit('chat.started', { id: requestId, sessionId, model: message.model });
          continue;
        }
        if (message.type === 'stream_event') {
          const delta = textDelta(message.event);
          if (delta !== null) this.#emit('chat.delta', { id: requestId, text: delta });
          continue;
        }
        if (message.type === 'assistant') {
          if (message.error === 'authentication_failed') {
            this.#authOk = false;
            throw new ProtocolError(
              'not_logged_in',
              'claude is installed but not logged in — run `claude` in a terminal and sign in',
            );
          }
          for (const summary of toolSummaries(message.message, params.root)) {
            this.#emit('chat.tool', { id: requestId, ...summary });
          }
          continue;
        }
        if (message.type === 'result') {
          if (sessionId === '') sessionId = message.session_id;
          if (message.subtype !== 'success' || message.is_error) {
            const detail = message.subtype === 'success' ? message.result : message.errors.join('; ');
            throw new ProtocolError(
              'agent_error',
              `the agent run failed (${message.subtype})`,
              detail,
            );
          }
          this.#authOk = true;
          this.#store.remember(params.root, sessionId);
          return {
            sessionId,
            text: message.result,
            numTurns: message.num_turns,
            usage: readUsage(message.usage),
            costUsd: message.total_cost_usd,
          };
        }
      }
    } catch (cause) {
      throw this.#translate(cause, abort);
    }
    throw new ProtocolError('agent_error', 'the agent stream ended without a result');
  }

  #buildOptions(root: string, resume: string | undefined, abort: AbortController): Options {
    return {
      cwd: root,
      env: this.#env,
      pathToClaudeCodeExecutable: this.#claudePath,
      abortController: abort,
      includePartialMessages: true,
      permissionMode: 'dontAsk',
      tools: [...CHAT_TOOLS],
      allowedTools: [...CHAT_TOOLS],
      disallowedTools: [...CHAT_DENIED_TOOLS],
      // Project settings bring the repo's CLAUDE.md; the tool lists above still
      // bind, so a permissive settings file cannot widen chat past read-only.
      settingSources: ['project'],
      ...(resume === undefined ? {} : { resume }),
      ...(this.#model === undefined ? {} : { model: this.#model }),
    };
  }

  #translate(cause: unknown, abort: AbortController): ProtocolError {
    if (cause instanceof ProtocolError) return cause;
    if (abort.signal.aborted) return new ProtocolError('cancelled', 'chat run cancelled');
    const message = cause instanceof Error ? cause.message : String(cause);
    if (/not found|ENOENT|failed to launch/i.test(message)) {
      return new ProtocolError('claude_not_found', 'could not launch the claude CLI', message);
    }
    return new ProtocolError('agent_error', 'the agent run failed', message);
  }
}

function toSummary(info: SDKSessionInfo): SessionSummary {
  const title = info.customTitle ?? info.firstPrompt ?? info.summary ?? info.sessionId;
  return { sessionId: info.sessionId, title, lastModified: info.lastModified };
}

function readUsage(usage: unknown): ChatDone['usage'] {
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

/** One dim status line per tool call, e.g. `reading src/foo.py`. */
export function toolSummaries(
  message: unknown,
  cwd: string,
): Array<{ tool: string; summary: string }> {
  const content = (message as { content?: unknown } | null)?.content;
  if (!Array.isArray(content)) return [];
  const out: Array<{ tool: string; summary: string }> = [];
  for (const block of content) {
    const b = block as { type?: string; name?: string; input?: Record<string, unknown> };
    if (b.type !== 'tool_use' || typeof b.name !== 'string') continue;
    out.push({ tool: b.name, summary: describeTool(b.name, b.input ?? {}, cwd) });
  }
  return out;
}

function describeTool(name: string, input: Record<string, unknown>, cwd: string): string {
  const text = (key: string): string | null =>
    typeof input[key] === 'string' && input[key] !== '' ? (input[key] as string) : null;
  const shortPath = (value: string): string => relative(cwd, value) || value;
  switch (name) {
    case 'Read': {
      const path = text('file_path');
      return path === null ? 'reading a file' : `reading ${shortPath(path)}`;
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

/** Best-effort text of a stored transcript message; shapes vary by producer. */
function extractText(message: unknown): string {
  const content = (message as { content?: unknown } | null)?.content;
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  return content
    .filter((block) => (block as { type?: string }).type === 'text')
    .map((block) => String((block as { text?: unknown }).text ?? ''))
    .join('')
    .trim();
}
