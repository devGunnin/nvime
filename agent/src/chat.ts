import type {
  GetSessionMessagesOptions,
  ListSessionsOptions,
  Options,
  SDKMessage,
  SDKSessionInfo,
  SessionMessage,
  SessionMutationOptions,
} from '@anthropic-ai/claude-agent-sdk';
import {
  composePrompt,
  stripContextSections,
  type ContextBlock,
  type ProjectInstructions,
} from './context.js';
import { dialOptions, type Dial } from './dial.js';
import { subscriptionEnv, type Env } from './env.js';
import { CHAT_OPTIONS_RULE, extractOptions, type OptionsBlock } from './options.js';
import { ProtocolError } from './protocol.js';
import { SessionStore } from './sessions.js';
import { readUsage, textDelta, toolCalls, type RunUsage } from './stream.js';

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

/** How deep `list` scans the SDK's sessions; a full page means truncation. */
export const LIST_SCAN_LIMIT = 200;

export interface SdkBindings {
  query: (params: { prompt: string; options?: Options }) => AsyncIterable<SDKMessage>;
  listSessions: (options?: ListSessionsOptions) => Promise<SDKSessionInfo[]>;
  getSessionMessages: (
    sessionId: string,
    options?: GetSessionMessagesOptions,
  ) => Promise<SessionMessage[]>;
  deleteSession: (sessionId: string, options?: SessionMutationOptions) => Promise<void>;
}

export type EmitEvent = (event: string, params: Record<string, unknown>) => void;

export interface SendParams extends Dial {
  root: string;
  prompt: string;
  context: ContextBlock[];
  sessionId?: string | undefined;
  /** Skips the stored "current" session fallback below — a deliberate fresh
   *  start even when this project has one on record. An explicit `sessionId`
   *  still wins over this: it only changes what an absent one falls back to. */
  new?: boolean | undefined;
  /** The project's CLAUDE.md/AGENTS.md/.nvime/instructions.md, or null when
   *  none was found or the feature is off. */
  projectInstructions?: ProjectInstructions | null | undefined;
}

export interface ChatDone {
  sessionId: string;
  text: string;
  numTurns: number;
  usage: RunUsage;
  costUsd: number;
  /** The choice this reply offered, when the model opted into one. */
  options: OptionsBlock | null;
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
}

export class ChatService {
  readonly #sdk: SdkBindings;
  readonly #store: SessionStore;
  readonly #claudePath: string;
  readonly #env: Env;
  readonly #emit: EmitEvent;
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
    const resume = params.sessionId ?? (params.new === true ? undefined : this.#store.get(params.root).current ?? undefined);
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
    const live = await this.#sdk.listSessions({ dir: root, limit: LIST_SCAN_LIMIT });
    const byId = new Map(live.map((info) => [info.sessionId, info]));
    // Only a complete, non-empty listing proves a session is gone. An empty one
    // is no information (moved store, different HOME, a read that failed inside
    // the SDK) and a full one is truncated — evicting on either would throw the
    // resume pointer away for good.
    if (live.length > 0 && live.length < LIST_SCAN_LIMIT) {
      this.#store.retain(root, new Set(byId.keys()));
    }
    const entry = this.#store.get(root);
    const sessions = entry.known
      .map((id) => byId.get(id))
      .filter((info): info is SDKSessionInfo => info !== undefined)
      .slice(0, limit)
      .map(toSummary);
    return { current: entry.current, sessions };
  }

  /** Deletes a stored session and its transcript, and drops it from the project's list. */
  async forget(root: string, sessionId: string): Promise<void> {
    await this.#sdk.deleteSession(sessionId, { dir: root });
    this.#store.forget(root, sessionId);
  }

  async history(root: string, sessionId: string, limit: number): Promise<
    Array<{ role: 'user' | 'assistant'; text: string }>
  > {
    const messages = await this.#sdk.getSessionMessages(sessionId, { dir: root, limit });
    const turns: Array<{ role: 'user' | 'assistant'; text: string }> = [];
    for (const message of messages) {
      if (message.type !== 'user' && message.type !== 'assistant') continue;
      const raw = extractText(message.message);
      // A user turn was stored with its attachments inlined; replay the prompt.
      const text = message.type === 'user' ? stripContextSections(raw).trim() : raw;
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
    const options = this.#buildOptions(params, resume, abort);
    const prompt = composePrompt(
      params.prompt,
      params.context,
      params.root,
      params.projectInstructions ?? null,
      CHAT_OPTIONS_RULE,
    );
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
          for (const call of toolCalls(message.message, params.root)) {
            this.#emit('chat.tool', { id: requestId, tool: call.tool, summary: call.summary });
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
          // The panel swallowed the options fence as it streamed; lift the
          // block out of the text so the stored turn reads the same way.
          const offered = extractOptions(message.result);
          return {
            sessionId,
            text: offered.text,
            numTurns: message.num_turns,
            usage: readUsage(message.usage),
            costUsd: message.total_cost_usd,
            options: offered.options,
          };
        }
      }
    } catch (cause) {
      throw this.#translate(cause, abort);
    }
    throw new ProtocolError('agent_error', 'the agent stream ended without a result');
  }

  #buildOptions(params: SendParams, resume: string | undefined, abort: AbortController): Options {
    return {
      cwd: params.root,
      // A copy per run: the SDK mutates the env object it is handed.
      env: { ...this.#env },
      pathToClaudeCodeExecutable: this.#claudePath,
      abortController: abort,
      includePartialMessages: true,
      permissionMode: 'dontAsk',
      tools: [...CHAT_TOOLS],
      allowedTools: [...CHAT_TOOLS],
      disallowedTools: [...CHAT_DENIED_TOOLS],
      // No filesystem settings. `'project'` would load the opened repo's
      // .claude/settings.json — whose `hooks` run shell commands and whose
      // `apiKeyHelper`/`env` re-add the credential env.ts just stripped, none
      // of them gated by the tool lists. Read-only cannot be voidable by the
      // repo being read. CLAUDE.md/AGENTS.md come back as an untrusted section
      // of the user message instead (`composePrompt`) — never `systemPrompt`,
      // which repo text must never reach.
      settingSources: [],
      ...(resume === undefined ? {} : { resume }),
      ...dialOptions(params),
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

/** A session with no title yet (created, but no prompt has landed) reads as
 *  "(new) <short id>" — the full id is meaningless to a reader, but two
 *  prompt-less sessions still have to be tellable apart before a delete. */
function toSummary(info: SDKSessionInfo): SessionSummary {
  const named = nonEmpty(info.customTitle) ?? nonEmpty(info.firstPrompt) ?? nonEmpty(info.summary);
  const title = named ?? `(new) ${info.sessionId.slice(0, 8)}`;
  return { sessionId: info.sessionId, title, lastModified: info.lastModified };
}

/** `??` alone would let a blank title through as a blank picker row. */
function nonEmpty(value: string | undefined | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed !== undefined && trimmed !== '' ? trimmed : undefined;
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
