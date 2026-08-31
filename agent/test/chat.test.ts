import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage, SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import {
  CHAT_DENIED_TOOLS,
  CHAT_TOOLS,
  ChatService,
  type SdkBindings,
} from '../src/chat.js';
import { ProtocolError } from '../src/protocol.js';
import { SessionStore } from '../src/sessions.js';

const ROOT = '/work/proj';
const SESSION = '11111111-2222-3333-4444-555555555555';

/** Minimal frames shaped like the SDK's, cast at the single boundary under test. */
const frames = {
  init: (sessionId = SESSION) =>
    ({ type: 'system', subtype: 'init', session_id: sessionId, model: 'claude-opus-5' }) as unknown as SDKMessage,
  delta: (text: string) =>
    ({
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
    }) as unknown as SDKMessage,
  tool: (name: string, input: Record<string, unknown>) =>
    ({
      type: 'assistant',
      message: { content: [{ type: 'tool_use', name, input }] },
    }) as unknown as SDKMessage,
  authFailure: () =>
    ({ type: 'assistant', error: 'authentication_failed', message: { content: [] } }) as unknown as SDKMessage,
  success: (text: string, sessionId = SESSION) =>
    ({
      type: 'result',
      subtype: 'success',
      is_error: false,
      result: text,
      session_id: sessionId,
      num_turns: 1,
      total_cost_usd: 0.01,
      usage: { input_tokens: 12, output_tokens: 3, cache_read_input_tokens: 1, cache_creation_input_tokens: 0 },
    }) as unknown as SDKMessage,
  failure: (errors: string[]) =>
    ({
      type: 'result',
      subtype: 'error_during_execution',
      is_error: true,
      errors,
      session_id: SESSION,
      num_turns: 1,
      total_cost_usd: 0,
      usage: {},
    }) as unknown as SDKMessage,
};

interface Harness {
  service: ChatService;
  store: SessionStore;
  events: Array<{ event: string; params: Record<string, unknown> }>;
  calls: Array<{ prompt: string; options: Options | undefined }>;
}

function harness(
  messages: SDKMessage[],
  storePath: string,
  overrides: Partial<SdkBindings> = {},
  env: Record<string, string | undefined> = { PATH: '/usr/bin', ANTHROPIC_API_KEY: 'leaked' },
): Harness {
  const events: Harness['events'] = [];
  const calls: Harness['calls'] = [];
  const sdk: SdkBindings = {
    query: ({ prompt, options }) => {
      calls.push({ prompt, options });
      return (async function* () {
        for (const message of messages) yield message;
      })();
    },
    listSessions: async () => [],
    getSessionMessages: async () => [],
    ...overrides,
  };
  const store = new SessionStore(storePath);
  const service = new ChatService({
    sdk,
    store,
    claudePath: '/usr/bin/claude',
    env,
    emit: (event, params) => events.push({ event, params }),
  });
  return { service, store, events, calls };
}

describe('ChatService.send', () => {
  let dir = '';
  let storePath = '';
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-chat-'));
    storePath = join(dir, 'sessions.json');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('streams deltas and tool lines, then returns the completion payload', async () => {
    const h = harness(
      [
        frames.init(),
        frames.delta('pi'),
        frames.tool('Read', { file_path: '/work/proj/src/foo.py' }),
        frames.delta('ng'),
        frames.success('ping'),
      ],
      storePath,
    );
    const done = await h.service.send(1, { root: ROOT, prompt: 'say ping', context: [] });

    assert.deepEqual(done, {
      sessionId: SESSION,
      text: 'ping',
      numTurns: 1,
      usage: { input: 12, output: 3, cacheRead: 1, cacheCreation: 0 },
      costUsd: 0.01,
    });
    assert.deepEqual(
      h.events.map((e) => [e.event, e.params.text ?? e.params.summary ?? e.params.sessionId]),
      [
        ['chat.started', SESSION],
        ['chat.delta', 'pi'],
        ['chat.tool', 'reading src/foo.py'],
        ['chat.delta', 'ng'],
      ],
    );
    assert.deepEqual(h.store.get(ROOT), { current: SESSION, known: [SESSION] });
  });

  it('runs read-only: research tools allowed, mutation and shell denied', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [] });
    const options = h.calls[0]?.options;
    assert.ok(options !== undefined);
    assert.deepEqual(options.tools, [...CHAT_TOOLS]);
    assert.deepEqual(options.allowedTools, [...CHAT_TOOLS]);
    assert.deepEqual(options.disallowedTools, [...CHAT_DENIED_TOOLS]);
    for (const denied of ['Bash', 'Edit', 'Write']) {
      assert.ok(!(options.tools as string[]).includes(denied), `${denied} must not be available`);
    }
    assert.equal(options.permissionMode, 'dontAsk');
    assert.equal(options.cwd, ROOT);
  });

  it('never forwards an API key to the SDK subprocess', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath, {}, {
      PATH: '/usr/bin',
      HOME: '/home/x',
      ANTHROPIC_API_KEY: 'sk-leak',
      ANTHROPIC_AUTH_TOKEN: 'tok-leak',
    });
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [] });
    const env = h.calls[0]?.options?.env;
    assert.ok(env !== undefined);
    assert.equal(env.ANTHROPIC_API_KEY, undefined);
    assert.equal(env.ANTHROPIC_AUTH_TOKEN, undefined);
    assert.equal(env.HOME, '/home/x', 'the rest of the environment still reaches the CLI');
    assert.equal(h.calls[0]?.options?.pathToClaudeCodeExecutable, '/usr/bin/claude');
  });

  it('attaches context blocks ahead of the prompt', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, {
      root: ROOT,
      prompt: 'explain this',
      context: [{ type: 'selection', path: '/work/proj/a.lua', startLine: 3, endLine: 4, text: 'local x = 1' }],
    });
    const prompt = h.calls[0]?.prompt ?? '';
    assert.match(prompt, /<context file="a\.lua" lines="3-4">/);
    assert.ok(prompt.endsWith('explain this'), 'the user prompt stays last');
  });

  it('resumes the project session recorded by the previous run', async () => {
    const first = harness([frames.init(), frames.success('one')], storePath);
    await first.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    assert.equal(first.calls[0]?.options?.resume, undefined, 'the first run starts fresh');

    const second = harness([frames.init(), frames.success('two')], storePath);
    await second.service.send(2, { root: ROOT, prompt: 'b', context: [] });
    assert.equal(second.calls[0]?.options?.resume, SESSION);
  });

  it('prefers an explicitly picked session over the stored one', async () => {
    const seed = harness([frames.init(), frames.success('one')], storePath);
    await seed.service.send(1, { root: ROOT, prompt: 'a', context: [] });

    const picked = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const h = harness([frames.init(picked), frames.success('two', picked)], storePath);
    await h.service.send(2, { root: ROOT, prompt: 'b', context: [], sessionId: picked });
    assert.equal(h.calls[0]?.options?.resume, picked);
    assert.equal(h.store.get(ROOT).current, picked);
  });

  it('reports a failed run instead of returning an empty reply', async () => {
    const h = harness([frames.init(), frames.failure(['upstream exploded'])], storePath);
    await assert.rejects(
      h.service.send(1, { root: ROOT, prompt: 'hi', context: [] }),
      (error: unknown) =>
        error instanceof ProtocolError &&
        error.code === 'agent_error' &&
        error.detail === 'upstream exploded',
    );
    assert.equal(h.store.get(ROOT).current, null, 'a failed run does not become the resume target');
  });

  it('maps an authentication failure to not_logged_in', async () => {
    const h = harness([frames.init(), frames.authFailure()], storePath);
    await assert.rejects(
      h.service.send(1, { root: ROOT, prompt: 'hi', context: [] }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'not_logged_in',
    );
    assert.equal(h.service.authOk, false);
  });

  it('maps a stream that ends without a result to an agent error', async () => {
    const h = harness([frames.init()], storePath);
    await assert.rejects(
      h.service.send(1, { root: ROOT, prompt: 'hi', context: [] }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'agent_error',
    );
  });

  it('reports a missing CLI as claude_not_found', async () => {
    const h = harness([], storePath, {
      query: () =>
        (async function* (): AsyncGenerator<SDKMessage> {
          throw new Error('Claude Code native binary not found at /usr/bin/claude');
        })(),
    });
    await assert.rejects(
      h.service.send(1, { root: ROOT, prompt: 'hi', context: [] }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'claude_not_found',
    );
  });

  it('refuses a second concurrent run for the same project', async () => {
    let release = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const h = harness([], storePath, {
      query: () =>
        (async function* (): AsyncGenerator<SDKMessage> {
          yield frames.init();
          await gate;
          yield frames.success('ok');
        })(),
    });
    const first = h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    await assert.rejects(
      h.service.send(2, { root: ROOT, prompt: 'b', context: [] }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'busy',
    );
    release();
    await first;
    assert.equal(h.service.activeRuns, 0, 'the run slot is released');
  });

  it('cancels an in-flight run', async () => {
    let parked = false;
    const h = harness([], storePath, {
      query: ({ options }) =>
        (async function* (): AsyncGenerator<SDKMessage> {
          yield frames.init();
          const signal = options?.abortController?.signal;
          assert.ok(signal !== undefined, 'the service must pass an abort signal to the SDK');
          parked = true;
          await new Promise<void>((resolve) => {
            if (signal.aborted) resolve();
            else signal.addEventListener('abort', () => resolve(), { once: true });
          });
          throw new Error('aborted');
        })(),
    });
    const pending = h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    await waitFor(() => parked);
    assert.equal(h.service.cancel(1), true);
    await assert.rejects(
      pending,
      (error: unknown) => error instanceof ProtocolError && error.code === 'cancelled',
    );
    assert.equal(h.service.cancel(1), false, 'cancelling a finished run is a no-op, not an error');
  });
});

describe('ChatService.list', () => {
  let dir = '';
  let storePath = '';
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-list-'));
    storePath = join(dir, 'sessions.json');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('shows only nvime sessions, titled and dated from the SDK', async () => {
    const live = [
      { sessionId: SESSION, summary: 'Ping', firstPrompt: 'say ping', lastModified: 42 },
      { sessionId: 'someone-elses', summary: 'Unrelated', lastModified: 99 },
    ] as unknown as SDKSessionInfo[];
    const h = harness([frames.init(), frames.success('ok')], storePath, {
      listSessions: async () => live,
    });
    await h.service.send(1, { root: ROOT, prompt: 'say ping', context: [] });

    const listed = await h.service.list(ROOT, 25);
    assert.equal(listed.current, SESSION);
    assert.deepEqual(listed.sessions, [{ sessionId: SESSION, title: 'say ping', lastModified: 42 }]);
  });

  it('forgets sessions the SDK has deleted', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath, { listSessions: async () => [] });
    await h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    const listed = await h.service.list(ROOT, 25);
    assert.deepEqual(listed, { current: null, sessions: [] });
  });
});

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('condition not reached before the deadline');
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
