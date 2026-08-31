import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { getSessionMessages, listSessions, query } from '@anthropic-ai/claude-agent-sdk';
import { ChatService } from './chat.js';
import { parseContextBlocks } from './context.js';
import { EditService, parseScope } from './edit.js';
import { resolveClaudeExecutable, strippedNames } from './env.js';
import {
  optionalPositiveInt,
  optionalString,
  requireAbsolutePath,
  requireArray,
  requireBoolean,
  requireString,
} from './params.js';
import { LineSplitter, ProtocolError, encodeFrame, type OutgoingFrame } from './protocol.js';
import { Dispatcher } from './rpc.js';
import { SessionStore, defaultStorePath } from './sessions.js';
import { CLAUDE_VERSION_PROBE_TIMEOUT_MS, DRAIN_TIMEOUT_MS } from './timeouts.js';

export { CLAUDE_VERSION_PROBE_TIMEOUT_MS, DRAIN_TIMEOUT_MS } from './timeouts.js';

export const AGENT_VERSION = '0.1.0';

const run = promisify(execFile);

/**
 * Frames handed to stdout but not yet flushed. On a pipe Node's stdout is
 * asynchronous and `process.exit` drops whatever is still queued, which would
 * cut a large final `chat.send` reply mid-frame.
 */
let unflushed = 0;

function write(frame: OutgoingFrame): void {
  const line = encodeFrame(frame);
  unflushed += 1;
  process.stdout.write(line, () => {
    unflushed -= 1;
  });
}

function main(): void {
  const claudePath = resolveClaudeExecutable(process.env);
  const store = new SessionStore(process.env.NVIME_SESSION_STORE ?? defaultStorePath(process.env));
  const chat =
    claudePath === null
      ? null
      : new ChatService({
          sdk: { query, listSessions, getSessionMessages },
          store,
          claudePath,
          env: process.env,
          emit: (event, params) => write({ event, params }),
          model: process.env.NVIME_MODEL,
        });

  const edit =
    claudePath === null
      ? null
      : new EditService({
          sdk: { query },
          claudePath,
          env: process.env,
          emit: (event, params) => write({ event, params }),
          model: process.env.NVIME_MODEL,
          approvalTimeoutMs: readApprovalTimeout(process.env.NVIME_APPROVAL_TIMEOUT_MS),
        });

  const dispatcher = new Dispatcher(write);
  registerHandlers(dispatcher, { chat, edit }, claudePath, store.path);
  readStdin(dispatcher);
}

interface Services {
  chat: ChatService | null;
  edit: EditService | null;
}

/**
 * The plugin owns this setting; a value it could not have sent is ignored so a
 * stray environment variable cannot silently disable the approval deadline.
 */
function readApprovalTimeout(raw: string | undefined): number | undefined {
  if (raw === undefined || raw === '') return undefined;
  const ms = Number(raw);
  if (!Number.isSafeInteger(ms) || ms < 1000) {
    process.stderr.write(`nvime: ignoring NVIME_APPROVAL_TIMEOUT_MS=${raw}\n`);
    return undefined;
  }
  return ms;
}

/** Every capability needs the CLI; without it the answer is one clear error. */
function present<T>(service: T | null): T {
  if (service === null) {
    throw new ProtocolError(
      'claude_not_found',
      'the claude CLI was not found on PATH — install Claude Code and sign in',
    );
  }
  return service;
}

/** The request id a `*.cancel` names. Not a params string: ids are integers. */
function requireTarget(params: Record<string, unknown>): number {
  const target = params.target;
  if (typeof target !== 'number' || !Number.isSafeInteger(target)) {
    throw new ProtocolError('bad_request', 'params.target must be the request id to cancel');
  }
  return target;
}

/**
 * Exits once every accepted request has been answered AND its frames have left
 * stdout, or the deadline passes. Without the first, closing stdin kills a
 * request still being served — the race a `:checkhealth` ping loses to a
 * `claude --version` lookup; without the second, the last reply is truncated.
 */
async function drainThenExit(dispatcher: Dispatcher): Promise<never> {
  const deadline = Date.now() + DRAIN_TIMEOUT_MS;
  while ((dispatcher.inflight > 0 || unflushed > 0) && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  process.exit(0);
}

function registerHandlers(
  dispatcher: Dispatcher,
  services: Services,
  claudePath: string | null,
  storePath: string,
): void {
  const { chat, edit } = services;
  let claudeVersion: string | null = null;

  dispatcher.register('ping', async () => {
    if (claudeVersion === null && claudePath !== null) {
      claudeVersion = await readClaudeVersion(claudePath);
    }
    return {
      agentVersion: AGENT_VERSION,
      node: process.version,
      claudePath,
      claudeVersion,
      authOk: chat?.authOk ?? null,
      activeRuns: (chat?.activeRuns ?? 0) + (edit?.activeRuns ?? 0),
      storePath,
      strippedEnv: strippedNames(process.env),
    };
  });

  dispatcher.register('shutdown', async () => {
    // Answer first, then let anything already running finish.
    setTimeout(() => void drainThenExit(dispatcher), 10).unref();
    return { ok: true };
  });

  dispatcher.register('chat.send', async (id, params) =>
    present(chat).send(id, {
      root: requireAbsolutePath(params, 'root'),
      prompt: requireString(params, 'prompt'),
      context: parseContextBlocks(requireArray(params, 'context')),
      sessionId: optionalString(params, 'sessionId'),
    }),
  );

  dispatcher.register('chat.list', async (_id, params) =>
    present(chat).list(
      requireAbsolutePath(params, 'root'),
      optionalPositiveInt(params, 'limit', 200) ?? 25,
    ),
  );

  dispatcher.register('chat.history', async (_id, params) => ({
    turns: await present(chat).history(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'sessionId'),
      optionalPositiveInt(params, 'limit', 500) ?? 100,
    ),
  }));

  dispatcher.register('chat.cancel', async (_id, params) => ({
    cancelled: present(chat).cancel(requireTarget(params)),
  }));

  dispatcher.register('edit.start', async (id, params) =>
    present(edit).start(id, {
      root: requireAbsolutePath(params, 'root'),
      prompt: requireString(params, 'prompt'),
      scope: parseScope(params.scope),
      sessionId: optionalString(params, 'sessionId'),
    }),
  );

  dispatcher.register('edit.cancel', async (_id, params) => ({
    cancelled: present(edit).cancel(requireTarget(params)),
  }));

  dispatcher.register('edit.answer', async (_id, params) => ({
    answered: present(edit).answer(requireString(params, 'approvalId'), requireBoolean(params, 'allow')),
  }));

  dispatcher.register('edit.list_changes', async (_id, params) => ({
    changes: present(edit).listChanges(
      requireAbsolutePath(params, 'root'),
      optionalString(params, 'runId'),
      optionalPositiveInt(params, 'limit', 500),
    ),
  }));

  // Seam for later phases: `big.*` (P3) registers here.
}

async function readClaudeVersion(claudePath: string): Promise<string | null> {
  try {
    const { stdout } = await run(claudePath, ['--version'], { timeout: CLAUDE_VERSION_PROBE_TIMEOUT_MS });
    return stdout.trim();
  } catch (cause) {
    process.stderr.write(`nvime: could not read claude version: ${String(cause)}\n`);
    return null;
  }
}

function readStdin(dispatcher: Dispatcher): void {
  const splitter = new LineSplitter();
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk: string) => {
    let lines: string[];
    try {
      lines = splitter.push(chunk);
    } catch (cause) {
      fail(`stdin desynchronized: ${String(cause)}`);
      return;
    }
    for (const line of lines) dispatcher.handleLine(line);
  });
  // Editor gone: answer what is already running, then leave.
  process.stdin.on('end', () => void drainThenExit(dispatcher));
  process.on('uncaughtException', (cause) => fail(`uncaught exception: ${String(cause.stack ?? cause)}`));
  process.on('unhandledRejection', (cause) => fail(`unhandled rejection: ${String(cause)}`));
}

/** Loud, non-zero exit: the plugin surfaces the stderr tail rather than hanging. */
function fail(message: string): never {
  process.stderr.write(`nvime-agent: ${message}\n`);
  process.exit(1);
}

main();
