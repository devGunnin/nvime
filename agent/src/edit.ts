import { relative } from 'node:path';
import type { HookInput, HookJSONOutput, Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { ApprovalGate, DEFAULT_APPROVAL_TIMEOUT_MS } from './approvals.js';
import type { SdkBindings } from './chat.js';
import { composePrompt, type ContextBlock } from './context.js';
import { subscriptionEnv, type Env } from './env.js';
import { classifyTool, FILE_PATH_KEYS, READ_ONLY_TOOLS, realPathOf } from './policy.js';
import { ProtocolError } from './protocol.js';
import { readSnapshot, sameSnapshot, snapshotBytes, type Snapshot } from './snapshot.js';
import { describeTool, readUsage, textDelta, toolCalls, toolResultIds, type RunUsage } from './stream.js';

/**
 * Edit mode. The agent may change files, but every change is intercepted,
 * recorded with its exact before/after, and pushed to the editor the moment
 * the tool finishes — so the buffer the user is looking at reflects reality
 * without a reload.
 *
 * The base tool set is explicit rather than the Claude Code preset: a tool
 * nvime has no policy for cannot appear here by way of an SDK upgrade.
 */
export const EDIT_TOOLS = [...READ_ONLY_TOOLS, 'Edit', 'Write', 'Bash'] as const;

/** Auto-allowed without a round trip. Read-only only — never a mutation. */
export const EDIT_AUTO_ALLOWED = [...READ_ONLY_TOOLS] as const;

/** Removed from the model's context: delegation and unsupervised shells. */
export const EDIT_DENIED_TOOLS = [
  'Task',
  'Agent',
  'SlashCommand',
  'NotebookEdit',
  'BashOutput',
  'KillShell',
] as const;

/** Most recent changes kept per project for the changeset view. */
export const MAX_TRACKED_CHANGES = 200;

/** Ceiling on the before/after text held for one project's change log. */
export const MAX_TRACKED_BYTES = 32 * 1024 * 1024;

export type EditScope =
  | { kind: 'project' }
  | { kind: 'file'; path: string }
  | { kind: 'selection'; path: string; startLine: number; endLine: number; text: string };

export interface EditStartParams {
  root: string;
  prompt: string;
  scope: EditScope;
  sessionId?: string | undefined;
}

/** One recorded file mutation: what the file was, and what the agent made it. */
export interface AppliedChange {
  runId: string;
  index: number;
  path: string;
  tool: string;
  at: number;
  before: Snapshot;
  after: Snapshot;
}

export interface EditDone {
  runId: string;
  sessionId: string;
  text: string;
  numTurns: number;
  usage: RunUsage;
  costUsd: number;
  changes: AppliedChange[];
}

export interface EditServiceOptions {
  sdk: Pick<SdkBindings, 'query'>;
  claudePath: string;
  env: Env;
  emit: (event: string, params: Record<string, unknown>) => void;
  model?: string | undefined;
  approvalTimeoutMs?: number | undefined;
}

interface Run {
  requestId: number;
  runId: string;
  root: string;
  realRoot: string;
  abort: AbortController;
  /** Tool-use id -> the file it is about to change, snapshotted before it ran. */
  pending: Map<string, { path: string; tool: string; before: Snapshot }>;
  approvalIds: Set<string>;
  changes: AppliedChange[];
}

let runCounter = 0;

export class EditService {
  readonly #sdk: Pick<SdkBindings, 'query'>;
  readonly #claudePath: string;
  readonly #env: Env;
  readonly #emit: EditServiceOptions['emit'];
  readonly #model: string | undefined;
  readonly #gate: ApprovalGate;
  readonly #running = new Map<number, Run>();
  readonly #runningByRoot = new Map<string, number>();
  /** Change log per real project root, newest last. Survives a run ending. */
  readonly #log = new Map<string, AppliedChange[]>();

  constructor(options: EditServiceOptions) {
    this.#sdk = options.sdk;
    this.#claudePath = options.claudePath;
    this.#env = subscriptionEnv(options.env);
    this.#emit = options.emit;
    this.#model = options.model;
    this.#gate = new ApprovalGate(options.approvalTimeoutMs ?? DEFAULT_APPROVAL_TIMEOUT_MS);
  }

  get activeRuns(): number {
    return this.#running.size;
  }

  get pendingApprovals(): number {
    return this.#gate.pending;
  }

  async start(requestId: number, params: EditStartParams): Promise<EditDone> {
    if (this.#runningByRoot.has(params.root)) {
      throw new ProtocolError('busy', 'an edit run is already in flight for this project');
    }
    runCounter += 1;
    const run: Run = {
      requestId,
      runId: `r${runCounter}`,
      root: params.root,
      realRoot: realPathOf(params.root),
      abort: new AbortController(),
      pending: new Map(),
      approvalIds: new Set(),
      changes: [],
    };
    this.#running.set(requestId, run);
    this.#runningByRoot.set(params.root, requestId);
    try {
      return await this.#drive(run, params);
    } catch (cause) {
      throw translate(cause, run.abort);
    } finally {
      this.#finishRun(run, 'the edit run ended');
      this.#running.delete(requestId);
      this.#runningByRoot.delete(params.root);
    }
  }

  /** True when a run was cancelled; false when there was nothing to cancel. */
  cancel(requestId: number): boolean {
    const run = this.#running.get(requestId);
    if (run === undefined) return false;
    run.abort.abort();
    return true;
  }

  /** Delivers the editor's answer to a parked approval. */
  answer(approvalId: string, allowed: boolean): boolean {
    return this.#gate.answer(approvalId, allowed);
  }

  /** The recorded changes for a project, oldest first. */
  listChanges(root: string, runId?: string, limit?: number): AppliedChange[] {
    const all = this.#log.get(realPathOf(root)) ?? [];
    const scoped = runId === undefined ? all : all.filter((change) => change.runId === runId);
    return limit === undefined ? [...scoped] : scoped.slice(Math.max(0, scoped.length - limit));
  }

  async #drive(run: Run, params: EditStartParams): Promise<EditDone> {
    const options = this.#buildOptions(run, params.sessionId);
    const prompt = composeEditPrompt(params.prompt, params.scope, run.root);
    let sessionId = params.sessionId ?? '';

    for await (const message of this.#sdk.query({ prompt, options })) {
      if (message.type === 'system' && message.subtype === 'init') {
        sessionId = message.session_id;
        this.#emit('edit.started', {
          id: run.requestId,
          runId: run.runId,
          sessionId,
          model: message.model,
        });
      } else if (message.type === 'stream_event') {
        const delta = textDelta(message.event);
        if (delta !== null) this.#emit('edit.delta', { id: run.requestId, text: delta });
      } else if (message.type === 'assistant') {
        this.#onAssistant(run, message);
      } else if (message.type === 'user') {
        for (const id of toolResultIds(message.message)) this.#settleMutation(run, id);
      } else if (message.type === 'result') {
        return this.#onResult(run, message, sessionId);
      }
    }
    throw new ProtocolError('agent_error', 'the agent stream ended without a result');
  }

  /**
   * Tool calls are tracked from the assistant message rather than only from
   * `canUseTool`: an auto-allowed call never reaches the callback, and a
   * mutation nvime failed to snapshot is a buffer that silently goes stale.
   */
  #onAssistant(run: Run, message: Extract<SDKMessage, { type: 'assistant' }>): void {
    if (message.error === 'authentication_failed') {
      throw new ProtocolError(
        'not_logged_in',
        'claude is installed but not logged in — run `claude` in a terminal and sign in',
      );
    }
    const content = (message.message as { content?: unknown }).content;
    const inputs = new Map<string, Record<string, unknown>>();
    if (Array.isArray(content)) {
      for (const block of content) {
        const b = block as { type?: string; id?: string; input?: Record<string, unknown> };
        if (b.type === 'tool_use' && typeof b.id === 'string') inputs.set(b.id, b.input ?? {});
      }
    }
    for (const call of toolCalls(message.message, run.root)) {
      this.#emit('edit.tool', { id: run.requestId, tool: call.tool, summary: call.summary });
      if (call.id !== '') this.#track(run, call.id, call.tool, inputs.get(call.id) ?? {});
    }
  }

  #onResult(
    run: Run,
    message: Extract<SDKMessage, { type: 'result' }>,
    sessionId: string,
  ): EditDone {
    this.#finishRun(run, 'the edit run ended');
    if (message.subtype !== 'success' || message.is_error) {
      const detail = message.subtype === 'success' ? message.result : message.errors.join('; ');
      throw new ProtocolError('agent_error', `the agent run failed (${message.subtype})`, detail);
    }
    return {
      runId: run.runId,
      sessionId: sessionId === '' ? message.session_id : sessionId,
      text: message.result,
      numTurns: message.num_turns,
      usage: readUsage(message.usage),
      costUsd: message.total_cost_usd,
      changes: [...run.changes],
    };
  }

  /**
   * Snapshots the file a tool is about to change. First write wins, so the
   * `before` is the earliest state seen — the callback and the assistant
   * message both land here and only one of them may be first.
   */
  #track(run: Run, toolUseId: string, tool: string, input: Record<string, unknown>): void {
    if (run.pending.has(toolUseId)) return;
    const key = FILE_PATH_KEYS[tool];
    if (key === undefined) return;
    const raw = input[key];
    if (typeof raw !== 'string' || raw === '') return;
    const path = realPathOf(raw);
    run.pending.set(toolUseId, { path, tool, before: readSnapshot(path) });
  }

  /**
   * The tool finished: read the file again and, if it really changed, record
   * the mutation and push it to the editor. A tool that errored or made no
   * difference produces no event — a phantom hunk is worse than none.
   */
  #settleMutation(run: Run, toolUseId: string): void {
    const pending = run.pending.get(toolUseId);
    if (pending === undefined) return;
    run.pending.delete(toolUseId);
    const after = readSnapshot(pending.path);
    if (sameSnapshot(pending.before, after)) return;
    const change: AppliedChange = {
      runId: run.runId,
      index: run.changes.length,
      path: pending.path,
      tool: pending.tool,
      at: Date.now(),
      before: pending.before,
      after,
    };
    run.changes.push(change);
    this.#record(run.realRoot, change);
    this.#emit('edit.applied', { id: run.requestId, ...change });
  }

  /** Oldest changes fall off once the log passes either budget. */
  #record(realRoot: string, change: AppliedChange): void {
    const log = this.#log.get(realRoot) ?? [];
    log.push(change);
    let bytes = log.reduce((sum, c) => sum + snapshotBytes(c.before) + snapshotBytes(c.after), 0);
    while (log.length > MAX_TRACKED_CHANGES || (bytes > MAX_TRACKED_BYTES && log.length > 1)) {
      const dropped = log.shift();
      if (dropped === undefined) break;
      bytes -= snapshotBytes(dropped.before) + snapshotBytes(dropped.after);
    }
    this.#log.set(realRoot, log);
  }

  /** Idempotent: flushes tool calls with no result, and unparks approvals. */
  #finishRun(run: Run, reason: string): void {
    for (const id of [...run.pending.keys()]) this.#settleMutation(run, id);
    for (const id of run.approvalIds) this.#gate.deny(id, reason);
    run.approvalIds.clear();
  }

  #buildOptions(run: Run, resume: string | undefined): Options {
    return {
      cwd: run.root,
      // A copy per run: the SDK mutates the env object it is handed.
      env: { ...this.#env },
      pathToClaudeCodeExecutable: this.#claudePath,
      abortController: run.abort,
      includePartialMessages: true,
      // Not `dontAsk`: edit mode's whole safety story is that the gated tools
      // reach `canUseTool`, and a mode that answers for them would skip it.
      permissionMode: 'default',
      tools: [...EDIT_TOOLS],
      allowedTools: [...EDIT_AUTO_ALLOWED],
      disallowedTools: [...EDIT_DENIED_TOOLS],
      canUseTool: (toolName, input, callbackOptions) =>
        this.#canUseTool(run, toolName, input, callbackOptions.toolUseID),
      // The callback alone is not enough: in `default` mode the CLI's own
      // safe-command classifier approves some shell calls without ever asking,
      // and a decision nvime never saw is a decision it did not make. This hook
      // runs first and forces the ask, so `canUseTool` really does see every
      // tool the policy will not auto-allow. Programmatic, not from settings.
      hooks: { PreToolUse: [{ hooks: [(input) => this.#preToolUse(run, input)] }] },
      // Same reasoning as chat: `'project'` would load the edited repo's
      // .claude/settings.json, whose hooks run shell commands and whose
      // apiKeyHelper/env re-add the credentials env.ts stripped — none of it
      // gated by the tool lists. Cost: no CLAUDE.md.
      settingSources: [],
      ...(resume === undefined ? {} : { resume }),
      ...(this.#model === undefined ? {} : { model: this.#model }),
    };
  }

  /**
   * Forces the permission prompt for anything the policy will not auto-allow,
   * ahead of every shortcut the CLI has for skipping one. Deferring (an empty
   * result) leaves the normal path alone, which is what an allowed tool wants.
   */
  async #preToolUse(run: Run, input: HookInput): Promise<HookJSONOutput> {
    if (input.hook_event_name !== 'PreToolUse') return { continue: true };
    const toolInput = (input.tool_input ?? {}) as Record<string, unknown>;
    const decision = classifyTool(input.tool_name, toolInput, run.realRoot);
    if (decision.kind === 'allow') return { continue: true };
    return {
      continue: true,
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: decision.kind,
        permissionDecisionReason: decision.reason,
      },
    };
  }

  /**
   * The enforcement point. Writes under the root run unattended and are
   * tracked; anything else parks until the editor answers, and never fails
   * open — see `policy.ts` for the classification and `approvals.ts` for the
   * deny-by-default exits.
   */
  async #canUseTool(
    run: Run,
    toolName: string,
    input: Record<string, unknown>,
    toolUseId: string,
  ): Promise<{ behavior: 'allow' } | { behavior: 'deny'; message: string }> {
    const decision = classifyTool(toolName, input, run.realRoot);
    if (decision.kind === 'deny') return { behavior: 'deny', message: decision.reason };
    if (decision.kind === 'allow') {
      this.#track(run, toolUseId, toolName, input);
      return { behavior: 'allow' };
    }
    const approvalId = `${run.runId}:${toolUseId}`;
    run.approvalIds.add(approvalId);
    this.#emit('edit.approval', {
      id: run.requestId,
      runId: run.runId,
      approvalId,
      tool: toolName,
      summary: describeTool(toolName, input, run.root),
      reason: decision.reason,
      ...(decision.path === undefined ? {} : { path: decision.path }),
    });
    const outcome = await this.#gate.request(approvalId, run.abort.signal);
    run.approvalIds.delete(approvalId);
    this.#emit('edit.approval_settled', { id: run.requestId, approvalId, allowed: outcome.allowed });
    if (!outcome.allowed) return { behavior: 'deny', message: outcome.reason };
    this.#track(run, toolUseId, toolName, input);
    return { behavior: 'allow' };
  }
}

/**
 * The instruction the agent actually receives. The scope is stated in words
 * because it steers the model; it is NOT what keeps the edit inside the
 * project — `canUseTool` is.
 */
export function composeEditPrompt(prompt: string, scope: EditScope, root: string): string {
  const blocks: ContextBlock[] = [];
  let where: string;
  if (scope.kind === 'project') {
    where = 'somewhere in this project';
  } else if (scope.kind === 'file') {
    where = `in ${relative(root, scope.path) || scope.path}`;
  } else {
    where = `in ${relative(root, scope.path) || scope.path}, lines ${scope.startLine}-${scope.endLine}`;
  }
  if (scope.kind === 'selection') {
    blocks.push({
      type: 'selection',
      path: scope.path,
      startLine: scope.startLine,
      endLine: scope.endLine,
      text: scope.text,
    });
  }
  const instruction =
    `Make the following change ${where}. Apply it directly with the Edit or Write tool — ` +
    'do not print a patch, and do not ask for confirmation. Keep the change minimal, ' +
    'then say in one or two sentences what you changed.';
  return composePrompt(`${instruction}\n\n${prompt}`, blocks, root);
}

/** Validates the `scope` param. Anything unrecognized is a `bad_request`. */
export function parseScope(raw: unknown): EditScope {
  if (raw === undefined || raw === null) return { kind: 'project' };
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ProtocolError('bad_request', 'params.scope must be an object');
  }
  const scope = raw as Record<string, unknown>;
  if (scope.kind === 'project') return { kind: 'project' };
  if (scope.kind !== 'file' && scope.kind !== 'selection') {
    throw new ProtocolError('bad_request', `params.scope.kind '${String(scope.kind)}' is not a scope`);
  }
  const path = scope.path;
  if (typeof path !== 'string' || path === '') {
    throw new ProtocolError('bad_request', 'params.scope.path must be a non-empty string');
  }
  if (scope.kind === 'file') return { kind: 'file', path };
  return {
    kind: 'selection',
    path,
    startLine: positiveInt(scope.startLine, 'params.scope.startLine'),
    endLine: positiveInt(scope.endLine, 'params.scope.endLine'),
    text: typeof scope.text === 'string' ? scope.text : '',
  };
}

function positiveInt(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    throw new ProtocolError('bad_request', `${label} must be a positive integer`);
  }
  return value;
}

function translate(cause: unknown, abort: AbortController): ProtocolError {
  if (cause instanceof ProtocolError) return cause;
  if (abort.signal.aborted) return new ProtocolError('cancelled', 'edit run cancelled');
  const message = cause instanceof Error ? cause.message : String(cause);
  if (/not found|ENOENT|failed to launch/i.test(message)) {
    return new ProtocolError('claude_not_found', 'could not launch the claude CLI', message);
  }
  return new ProtocolError('agent_error', 'the agent run failed', message);
}
