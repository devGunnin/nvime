import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { getSessionMessages, listSessions, query } from '@anthropic-ai/claude-agent-sdk';
import { BigService } from './big.js';
import { BigStore, defaultBigRoot } from './bigstore.js';
import { ChatService } from './chat.js';
import { parseContextBlocks, parseProjectInstructions } from './context.js';
import { EditService, parseScope } from './edit.js';
import { resolveClaudeExecutable, strippedNames } from './env.js';
import { DEFAULT_DIFFICULTY, DIFFICULTIES, isDifficulty, type Difficulty } from './gate.js';
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

export const AGENT_VERSION = '2.0.0';

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

  const bigStore = new BigStore(process.env.NVIME_BIG_ROOT ?? defaultBigRoot(process.env));
  const big =
    claudePath === null
      ? null
      : new BigService({
          sdk: { query },
          store: bigStore,
          claudePath,
          env: process.env,
          emit: (event, params) => write({ event, params }),
          model: process.env.NVIME_MODEL,
        });

  const dispatcher = new Dispatcher(write);
  registerHandlers(dispatcher, { chat, edit, big }, claudePath, store.path);
  readStdin(dispatcher);
}

interface Services {
  chat: ChatService | null;
  edit: EditService | null;
  big: BigService | null;
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
  const { chat, edit, big } = services;
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
      activeRuns: (chat?.activeRuns ?? 0) + (edit?.activeRuns ?? 0) + (big?.activeRuns ?? 0),
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
      projectInstructions: parseProjectInstructions(params.projectInstructions),
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
      projectInstructions: parseProjectInstructions(params.projectInstructions),
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

  registerBigHandlers(dispatcher, big);
}

/**
 * Big Change mode. Every method names the project root and, past `create`, the
 * session it acts on; the sidecar holds no "current" big change, so two open
 * editors cannot disagree about which one a keystroke meant.
 */
function registerBigHandlers(dispatcher: Dispatcher, big: BigService | null): void {
  dispatcher.register('big.create', async (_id, params) => ({
    session: present(big).create(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'title'),
      requireDifficulty(params),
    ),
  }));

  dispatcher.register('big.difficulty', async (_id, params) => ({
    session: present(big).setDifficulty(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'sessionId'),
      requireDifficulty(params),
    ),
  }));

  dispatcher.register('big.list', async (_id, params) => ({
    sessions: present(big).list(requireAbsolutePath(params, 'root')),
  }));

  dispatcher.register('big.open', async (_id, params) => ({
    session: present(big).open(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  }));

  dispatcher.register('big.diff', async (_id, params) => ({
    diff: present(big).diff(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  }));

  dispatcher.register('big.intake', async (id, params) => ({
    session: await present(big).intake(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      message: requireString(params, 'message'),
    }),
  }));

  dispatcher.register('big.approve', async (_id, params) => ({
    session: await present(big).approve(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  }));

  dispatcher.register('big.build', async (id, params) => ({
    session: await present(big).build(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
    }),
  }));

  dispatcher.register('big.capture', async (id, params) => ({
    session: await present(big).capture(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
    }),
  }));

  dispatcher.register('big.revise', async (id, params) => ({
    session: await present(big).revise(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      blockId: requireString(params, 'blockId'),
      comment: requireString(params, 'comment'),
    }),
  }));

  dispatcher.register('big.toggle', async (_id, params) => ({
    session: present(big).toggleBlock(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'sessionId'),
      requireString(params, 'blockId'),
      requireBoolean(params, 'resolved'),
    ),
  }));

  dispatcher.register('big.discard', async (_id, params) =>
    present(big).discard(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  );

  dispatcher.register('big.answer', async (id, params) => ({
    session: await present(big).answer(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      answers: parseAnswers(params.answers),
    }),
  }));

  dispatcher.register('big.mergecheck', async (_id, params) =>
    present(big).mergeCheck(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  );

  dispatcher.register('big.merge', async (id, params) =>
    present(big).merge(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      cleanup: params.cleanup === true,
    }),
  );

  dispatcher.register('big.explain', async (id, params) =>
    present(big).explain(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      blockId: requireString(params, 'blockId'),
    }),
  );

  dispatcher.register('big.rebase', async (id, params) => ({
    session: await present(big).rebase(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
    }),
  }));

  dispatcher.register('big.cancel', async (_id, params) => ({
    cancelled: present(big).cancel(requireTarget(params)),
  }));
}

/** The gate's difficulty, named by the plugin. Anything else is a bad request. */
function requireDifficulty(params: Record<string, unknown>): Difficulty {
  const value = params.difficulty ?? DEFAULT_DIFFICULTY;
  if (!isDifficulty(value)) {
    throw new ProtocolError('bad_request', `params.difficulty must be one of: ${DIFFICULTIES.join(', ')}`);
  }
  return value;
}

/** One round of defense, shape-checked before any of it reaches a grader. */
function parseAnswers(raw: unknown): Array<{ blockId: string; text: string }> {
  if (!Array.isArray(raw)) throw new ProtocolError('bad_request', 'params.answers must be an array');
  return raw.map((entry) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new ProtocolError('bad_request', 'each answer must be an object');
    }
    const record = entry as Record<string, unknown>;
    return {
      blockId: requireString(record, 'blockId'),
      text: requireString(record, 'text'),
    };
  });
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
