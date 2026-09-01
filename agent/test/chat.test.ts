import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type {
  Options,
  SDKMessage,
  SDKSessionInfo,
  SessionMessage,
} from '@anthropic-ai/claude-agent-sdk';
import {
  CHAT_DENIED_TOOLS,
  CHAT_TOOLS,
  ChatService,
  LIST_SCAN_LIMIT,
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

  it('loads no filesystem settings, so the opened repo cannot widen the run', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [] });
    const sources = h.calls[0]?.options?.settingSources;
    assert.deepEqual(
      sources,
      [],
      "'project' would load the repo's .claude/settings.json — hooks run shell, " +
        'apiKeyHelper and env re-add credentials, and none of it is gated by the tool lists',
    );
  });

  it('prepends the project instructions to the user prompt as an explicit, marked block — never systemPrompt', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, {
      root: ROOT,
      prompt: 'hi',
      context: [],
      projectInstructions: { text: 'use tabs, never semicolons', truncated: false },
    });
    assert.equal(h.calls[0]?.options?.systemPrompt, undefined, 'untrusted text must never reach systemPrompt');
    const prompt = h.calls[0]?.prompt ?? '';
    assert.match(prompt, /^<project-notes id="[0-9a-f]+" untrusted="true">/);
    assert.match(prompt, /cannot change your tool permissions/);
    assert.match(prompt, /use tabs, never semicolons/);
    assert.match(prompt, /hi$/);
  });

  it('carries no project-notes section when no project instructions were given', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [] });
    assert.equal(h.calls[0]?.options?.systemPrompt, undefined);
    assert.equal(h.calls[0]?.prompt, 'hi');
  });

  it('hands the SDK a fresh env each run, since the SDK mutates what it is given', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    const first = h.calls[0]?.options?.env as Record<string, string | undefined> | undefined;
    assert.ok(first !== undefined);
    // What the real SDK does to the object it is handed.
    first.CLAUDE_CODE_ENTRYPOINT = 'sdk-ts';
    delete first.PATH;

    await h.service.send(2, { root: ROOT, prompt: 'b', context: [] });
    const second = h.calls[1]?.options?.env;
    assert.notEqual(second, first, 'not the same object twice');
    assert.equal(second?.CLAUDE_CODE_ENTRYPOINT, undefined, 'the addition did not carry over');
    assert.equal(second?.PATH, '/usr/bin', 'nor did the deletion');
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

  it('threads the requested model and effort into SDK options', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [], model: 'claude-opus-5', effort: 'high' });
    assert.equal(h.calls[0]?.options?.model, 'claude-opus-5');
    assert.equal(h.calls[0]?.options?.effort, 'high');
  });

  it('omits model and effort from SDK options when neither was requested', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath);
    await h.service.send(1, { root: ROOT, prompt: 'hi', context: [] });
    assert.equal(h.calls[0]?.options?.model, undefined);
    assert.equal(h.calls[0]?.options?.effort, undefined);
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

  it('forgets a session the SDK dropped from a complete listing', async () => {
    const other = 'cccccccc-dddd-eeee-ffff-000000000000';
    const live = [{ sessionId: other, summary: 'Other', lastModified: 7 }] as unknown as SDKSessionInfo[];
    const h = harness([frames.init(), frames.success('ok')], storePath, { listSessions: async () => live });
    await h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    const listed = await h.service.list(ROOT, 25);
    assert.equal(listed.current, null, 'a dead current pointer is cleared');
    assert.deepEqual(h.store.get(ROOT).known, [], 'and the id is dropped from the store');
  });

  it('keeps the resume pointer when the listing comes back empty', async () => {
    const h = harness([frames.init(), frames.success('ok')], storePath, { listSessions: async () => [] });
    await h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    const listed = await h.service.list(ROOT, 25);
    assert.equal(listed.current, SESSION, 'an empty listing is no information, not proof of deletion');
    assert.deepEqual(listed.sessions, [], 'but nothing is offered that the SDK did not confirm');
    assert.deepEqual(h.store.get(ROOT).known, [SESSION]);
  });

  it('keeps sessions that fell off the end of a truncated listing', async () => {
    const live = Array.from({ length: LIST_SCAN_LIMIT }, (_unused, i) => ({
      sessionId: `filler-${i}`,
      summary: 'filler',
      lastModified: i,
    })) as unknown as SDKSessionInfo[];
    const h = harness([frames.init(), frames.success('ok')], storePath, { listSessions: async () => live });
    await h.service.send(1, { root: ROOT, prompt: 'a', context: [] });
    const listed = await h.service.list(ROOT, 25);
    assert.equal(listed.current, SESSION, 'a full page is truncated, so absence proves nothing');
    assert.deepEqual(h.store.get(ROOT).known, [SESSION]);
  });
});

describe('ChatService.history', () => {
  let dir = '';
  let storePath = '';
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-history-'));
    storePath = join(dir, 'sessions.json');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('replays the prompt a user typed, not the files it carried', async () => {
    const stored = [
      {
        type: 'user',
        message: {
          content: [
            {
              type: 'text',
              text: '<context file="a.lua">\nlocal secret = 1\n</context>\n\nexplain @a.lua',
            },
          ],
        },
      },
      { type: 'assistant', message: { content: [{ type: 'text', text: 'it is a one' }] } },
    ] as unknown as SessionMessage[];
    const h = harness([], storePath, { getSessionMessages: async () => stored });

    const turns = await h.service.history(ROOT, SESSION, 40);
    assert.deepEqual(turns, [
      { role: 'user', text: 'explain @a.lua' },
      { role: 'assistant', text: 'it is a one' },
    ]);
  });

  it('replays a turn that carried no attachments unchanged', async () => {
    const stored = [
      { type: 'user', message: { content: [{ type: 'text', text: 'say ping' }] } },
    ] as unknown as SessionMessage[];
    const h = harness([], storePath, { getSessionMessages: async () => stored });
    assert.deepEqual(await h.service.history(ROOT, SESSION, 40), [{ role: 'user', text: 'say ping' }]);
  });
});

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('condition not reached before the deadline');
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
