import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { getSessionMessages, listSessions, query } from '@anthropic-ai/claude-agent-sdk';
import { ChatService } from './chat.js';
import { parseContextBlocks } from './context.js';
import { resolveClaudeExecutable, strippedNames } from './env.js';
import {
  optionalPositiveInt,
  optionalString,
  requireAbsolutePath,
  requireArray,
  requireString,
} from './params.js';
import { LineSplitter, ProtocolError, encodeFrame, type OutgoingFrame } from './protocol.js';
import { Dispatcher } from './rpc.js';
import { SessionStore, defaultStorePath } from './sessions.js';

export const AGENT_VERSION = '0.1.0';

/** How long a shutdown waits for in-flight requests to answer before exiting. */
export const DRAIN_TIMEOUT_MS = 5000;

const run = promisify(execFile);

function write(frame: OutgoingFrame): void {
  process.stdout.write(encodeFrame(frame));
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

  const dispatcher = new Dispatcher(write);
  registerHandlers(dispatcher, chat, claudePath, store.path);
  readStdin(dispatcher);
}

function requireChat(chat: ChatService | null): ChatService {
  if (chat === null) {
    throw new ProtocolError(
      'claude_not_found',
      'the claude CLI was not found on PATH — install Claude Code and sign in',
    );
  }
  return chat;
}

/**
 * Exits once every accepted request has been answered, or the deadline passes.
 * Without this, closing stdin kills a request that is still being served — the
 * exact race a `:checkhealth` ping loses to a `claude --version` lookup.
 */
async function drainThenExit(dispatcher: Dispatcher): Promise<never> {
  const deadline = Date.now() + DRAIN_TIMEOUT_MS;
  while (dispatcher.inflight > 0 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  process.exit(0);
}

function registerHandlers(
  dispatcher: Dispatcher,
  chat: ChatService | null,
  claudePath: string | null,
  storePath: string,
): void {
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
      activeRuns: chat?.activeRuns ?? 0,
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
    requireChat(chat).send(id, {
      root: requireAbsolutePath(params, 'root'),
      prompt: requireString(params, 'prompt'),
      context: parseContextBlocks(requireArray(params, 'context')),
      sessionId: optionalString(params, 'sessionId'),
    }),
  );

  dispatcher.register('chat.list', async (_id, params) =>
    requireChat(chat).list(
      requireAbsolutePath(params, 'root'),
      optionalPositiveInt(params, 'limit', 200) ?? 25,
    ),
  );

  dispatcher.register('chat.history', async (_id, params) => ({
    turns: await requireChat(chat).history(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'sessionId'),
      optionalPositiveInt(params, 'limit', 500) ?? 100,
    ),
  }));

  dispatcher.register('chat.cancel', async (_id, params) => {
    const target = params.target;
    if (typeof target !== 'number' || !Number.isSafeInteger(target)) {
      throw new ProtocolError('bad_request', 'params.target must be the request id to cancel');
    }
    return { cancelled: requireChat(chat).cancel(target) };
  });

  // Seam for later phases: `edit.*` (P2) and `big.*` (P3) register here.
}

async function readClaudeVersion(claudePath: string): Promise<string | null> {
  try {
    const { stdout } = await run(claudePath, ['--version'], { timeout: 10_000 });
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
