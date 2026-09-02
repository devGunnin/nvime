import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { isAbsolute } from 'node:path';
import { promisify } from 'node:util';
import { deleteSession, getSessionMessages, listSessions, query } from '@anthropic-ai/claude-agent-sdk';
import { BigService } from './big.js';
import { BigStore, defaultBigRoot } from './bigstore.js';
import { CertificationService } from './certification.js';
import { ChatService } from './chat.js';
import { parseContextBlocks, parseProjectInstructions } from './context.js';
import { DetachedService } from './detached.js';
import { parseDial, parseTriageDial } from './dial.js';
import { EditService, parseScope } from './edit.js';
import { resolveClaudeExecutable, strippedNames } from './env.js';
import { DEFAULT_DIFFICULTY, DIFFICULTIES, isDifficulty, type Difficulty } from './gate.js';
import {
  optionalBoolean,
  optionalPositiveInt,
  optionalString,
  requireAbsolutePath,
  requireArray,
  requireBoolean,
  requireString,
  requireUuid,
} from './params.js';
import { LineSplitter, ProtocolError, encodeFrame, type OutgoingFrame } from './protocol.js';
import { ManagedPolicyClient } from './managed-policy.js';
import { Dispatcher } from './rpc.js';
import { SessionStore, defaultStorePath } from './sessions.js';
import { CLAUDE_VERSION_PROBE_TIMEOUT_MS, DRAIN_TIMEOUT_MS } from './timeouts.js';

export { CLAUDE_VERSION_PROBE_TIMEOUT_MS, DRAIN_TIMEOUT_MS } from './timeouts.js';

export const AGENT_VERSION = '3.1.0';

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
          sdk: { query, listSessions, getSessionMessages, deleteSession },
          store,
          claudePath,
          env: process.env,
          emit: (event, params) => write({ event, params }),
        });

  const edit =
    claudePath === null
      ? null
      : new EditService({
          sdk: { query },
          claudePath,
          env: process.env,
          emit: (event, params) => write({ event, params }),
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
        });

  const detached =
    big === null
      ? null
      : new DetachedService({
          big,
          store: bigStore,
          env: process.env,
          emit: (event, params) => write({ event, params }),
        });

  const organization = createCertificationService(process.env);

  const dispatcher = new Dispatcher(write);
  registerHandlers(dispatcher, { chat, edit, big, detached, organization }, claudePath, store.path);
  readStdin(dispatcher);
}

interface Services {
  chat: ChatService | null;
  edit: EditService | null;
  big: BigService | null;
  detached: DetachedService | null;
  organization: CertificationService | null;
}

function createCertificationService(environment: NodeJS.ProcessEnv): CertificationService | null {
  const endpoint = environment.NVIME_CONTROL_PLANE_URL?.trim();
  if (!endpoint) return null;
  const trust = environment.NVIME_TRUST_PATH?.trim();
  const identity = environment.NVIME_IDENTITY_DIR?.trim();
  const github = environment.NVIME_GITHUB_PATH?.trim() || 'gh';
  if (!trust || !identity) throw new Error('managed nvime requires NVIME_TRUST_PATH and NVIME_IDENTITY_DIR');
  if (!isAbsolute(trust) || !isAbsolute(identity)) throw new Error('managed nvime trust paths must be absolute');
  const service = new CertificationService(new ManagedPolicyClient(endpoint), trust, identity, github);
  assert(endpoint.length > 0, 'managed control-plane endpoint must not be empty');
  assert(github.length > 0, 'managed GitHub executable must not be empty');
  return service;
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

function managed(service: CertificationService | null): CertificationService {
  if (service === null) {
    throw new ProtocolError('bad_request', 'organization control plane is not configured');
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
  const { chat, edit, big, detached, organization } = services;
  registerCoreHandlers(dispatcher, services, claudePath, storePath);
  registerOrganizationHandlers(dispatcher, big, organization);
  registerChatHandlers(dispatcher, chat);
  registerEditHandlers(dispatcher, edit);
  registerBigHandlers(dispatcher, big, detached);
}

function registerCoreHandlers(
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
}

function registerOrganizationHandlers(
  dispatcher: Dispatcher,
  big: BigService | null,
  organization: CertificationService | null,
): void {
  dispatcher.register('organization.policy', async () => managed(organization).policy());
  dispatcher.register('organization.enrollment', async (_id, params) =>
    managed(organization).enrollment(requireAbsolutePath(params, 'root')),
  );
  dispatcher.register('organization.attest', async (_id, params) => {
    const session = present(big).open(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'sessionId'),
    );
    return managed(organization).attest(session);
  });
}

function registerChatHandlers(dispatcher: Dispatcher, chat: ChatService | null): void {
  dispatcher.register('chat.send', async (id, params) =>
    present(chat).send(id, {
      root: requireAbsolutePath(params, 'root'),
      prompt: requireString(params, 'prompt'),
      context: parseContextBlocks(requireArray(params, 'context')),
      sessionId: optionalString(params, 'sessionId'),
      new: optionalBoolean(params, 'new'),
      projectInstructions: parseProjectInstructions(params.projectInstructions),
      ...parseDial(params),
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

  dispatcher.register('chat.forget', async (_id, params) => {
    const existed = await present(chat).forget(
      requireAbsolutePath(params, 'root'),
      requireUuid(params, 'sessionId'),
    );
    return { forgotten: true, alreadyGone: !existed };
  });

  dispatcher.register('chat.cancel', async (_id, params) => ({
    cancelled: present(chat).cancel(requireTarget(params)),
  }));
}

function registerEditHandlers(dispatcher: Dispatcher, edit: EditService | null): void {
  dispatcher.register('edit.start', async (id, params) =>
    present(edit).start(id, {
      root: requireAbsolutePath(params, 'root'),
      prompt: requireString(params, 'prompt'),
      scope: parseScope(params.scope),
      sessionId: optionalString(params, 'sessionId'),
      projectInstructions: parseProjectInstructions(params.projectInstructions),
      ...parseDial(params),
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
}

/**
 * Big Change mode. Every method names the project root and, past `create`, the
 * session it acts on; the sidecar holds no "current" big change, so two open
 * editors cannot disagree about which one a keystroke meant.
 */
function registerBigHandlers(
  dispatcher: Dispatcher,
  big: BigService | null,
  detached: DetachedService | null,
): void {
  dispatcher.register('big.create', async (_id, params) => ({
    session: present(big).create(
      requireAbsolutePath(params, 'root'),
      requireString(params, 'title'),
      requireDifficulty(params),
      optionalPositiveInt(params, 'threshold', 100),
      optionalString(params, 'policyId') ?? null,
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
      ...parseDial(params),
    }),
  }));

  dispatcher.register('big.approve', async (_id, params) => ({
    session: await present(big).approve(requireAbsolutePath(params, 'root'), requireString(params, 'sessionId')),
  }));

  dispatcher.register('big.build', async (id, params) => ({
    session: await present(detached).start(id, 'build', {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      ...parseDial(params),
      ...parseTriageDial(params),
    }),
  }));

  dispatcher.register('big.capture', async (id, params) => ({
    session: await present(big).capture(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      ...parseDial(params),
      ...parseTriageDial(params),
    }),
  }));

  dispatcher.register('big.revise', async (id, params) => ({
    session: await present(detached).start(id, 'revise', {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      blockId: requireString(params, 'blockId'),
      comment: requireString(params, 'comment'),
      ...parseDial(params),
      ...parseTriageDial(params),
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
      ...parseDial(params),
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
      ...parseDial(params),
    }),
  );

  dispatcher.register('big.rebase', async (id, params) => ({
    session: await present(detached).start(id, 'rebase', {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      ...parseDial(params),
      ...parseTriageDial(params),
    }),
  }));

  // Read-only: replays the build log from `after`, then follows the runner live.
  // Long-lived, like a build — it answers when the run ends or `big.detach`
  // lets go, so several editors can watch one build at once.
  dispatcher.register('big.attach', async (id, params) =>
    present(detached).attach(id, {
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      after: optionalSeq(params, 'after'),
    }),
  );

  dispatcher.register('big.steer', async (_id, params) =>
    present(detached).steer({
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
      text: requireString(params, 'text'),
    }),
  );

  dispatcher.register('big.stop', async (_id, params) =>
    present(detached).stop({
      root: requireAbsolutePath(params, 'root'),
      id: requireString(params, 'sessionId'),
    }),
  );

  dispatcher.register('big.detach', async (_id, params) => ({
    detached: present(detached).detach(requireTarget(params)),
  }));

  // A detached build has no in-process run to abort, so the runner is asked
  // first; a build still inside this sidecar falls through to the old path.
  dispatcher.register('big.cancel', async (_id, params) => {
    const target = requireTarget(params);
    if (detached !== null && (await detached.cancel(target))) return { cancelled: true };
    return { cancelled: present(big).cancel(target) };
  });
}

/** The `after` cursor an attach resumes from. 0 means "replay everything". */
function optionalSeq(params: Record<string, unknown>, key: string): number {
  const value = params[key];
  if (value === undefined || value === null) return 0;
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw new ProtocolError('bad_request', `params.${key} must be an integer >= 0`);
  }
  return value;
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
