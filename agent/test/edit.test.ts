import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import {
  EDIT_AUTO_ALLOWED,
  EDIT_DENIED_TOOLS,
  EDIT_TOOLS,
  EditService,
  composeEditPrompt,
  parseScope,
  type AppliedChange,
} from '../src/edit.js';
import { FILE_PATH_KEYS, realPathOf } from '../src/policy.js';
import { ProtocolError } from '../src/protocol.js';

const SESSION = '11111111-2222-3333-4444-555555555555';

const frames = {
  init: (sessionId = SESSION) =>
    ({ type: 'system', subtype: 'init', session_id: sessionId, model: 'claude-opus-5' }) as unknown as SDKMessage,
  delta: (text: string) =>
    ({
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
    }) as unknown as SDKMessage,
  toolUse: (id: string, name: string, input: Record<string, unknown>) =>
    ({
      type: 'assistant',
      message: { content: [{ type: 'tool_use', id, name, input }] },
    }) as unknown as SDKMessage,
  toolResult: (id: string) =>
    ({
      type: 'user',
      message: { content: [{ type: 'tool_result', tool_use_id: id }] },
    }) as unknown as SDKMessage,
  success: (text: string, sessionId = SESSION) =>
    ({
      type: 'result',
      subtype: 'success',
      is_error: false,
      result: text,
      session_id: sessionId,
      num_turns: 1,
      total_cost_usd: 0.02,
      usage: { input_tokens: 10, output_tokens: 4 },
    }) as unknown as SDKMessage,
};

/** A scripted turn: yield a frame, or run the tool the way the CLI would. */
type Step = { yield: SDKMessage } | { act: (options: Options) => Promise<void> };

interface Event {
  event: string;
  params: Record<string, unknown>;
}

interface Harness {
  service: EditService;
  events: Event[];
  calls: Array<{ prompt: string; options: Options }>;
}

/**
 * Runs a tool call the way the real pipeline does: `canUseTool` first, and the
 * write only if it came back allowed. `denied` collects the refusals so a test
 * can assert the tool never ran.
 */
function toolStep(
  toolUseId: string,
  name: string,
  input: Record<string, unknown>,
  perform: () => void,
  denied: string[],
): Step {
  return {
    act: async (options: Options) => {
      const decide = options.canUseTool;
      assert.ok(decide !== undefined, 'edit mode must install a permission callback');
      const result = await decide(name, input, {
        signal: new AbortController().signal,
        toolUseID: toolUseId,
        requestId: `req-${toolUseId}`,
      });
      if (result !== null && result.behavior === 'allow') perform();
      else denied.push(result === null ? 'null' : result.message);
    },
  };
}

function harness(
  steps: Step[],
  options: { approvalTimeoutMs?: number; onEvent?: (event: Event, service: EditService) => void } = {},
): Harness {
  const events: Event[] = [];
  const calls: Harness['calls'] = [];
  let service: EditService;
  const sdk = {
    query: ({ prompt, options: queryOptions }: { prompt: string; options?: Options }) => {
      assert.ok(queryOptions !== undefined, 'the service always builds options');
      calls.push({ prompt, options: queryOptions });
      return (async function* () {
        for (const step of steps) {
          if ('yield' in step) yield step.yield;
          else await step.act(queryOptions);
        }
      })();
    },
  };
  service = new EditService({
    sdk,
    claudePath: '/usr/bin/claude',
    env: { PATH: '/usr/bin', ANTHROPIC_API_KEY: 'leaked' },
    emit: (event, params) => {
      const record = { event, params };
      events.push(record);
      options.onEvent?.(record, service);
    },
    ...(options.approvalTimeoutMs === undefined ? {} : { approvalTimeoutMs: options.approvalTimeoutMs }),
  });
  return { service, events, calls };
}

describe('EditService: the SDK options contract', () => {
  it('never auto-allows a tool that can change a file', () => {
    for (const tool of EDIT_AUTO_ALLOWED) {
      assert.equal(
        FILE_PATH_KEYS[tool],
        undefined,
        `${tool} is auto-allowed, so it would bypass canUseTool entirely`,
      );
    }
  });

  it('offers no delegating or unsupervised-shell tool at all', () => {
    for (const denied of ['Task', 'Agent', 'SlashCommand']) {
      assert.ok(!(EDIT_TOOLS as readonly string[]).includes(denied), denied);
      assert.ok((EDIT_DENIED_TOOLS as readonly string[]).includes(denied), denied);
    }
  });

  it('runs with no filesystem settings and a permission mode that still asks', async () => {
    const h = harness([{ yield: frames.init() }, { yield: frames.success('done') }]);
    await h.service.start(1, { root: '/work/proj', prompt: 'go', scope: { kind: 'project' } });
    const options = h.calls[0]?.options;
    assert.deepEqual(options?.settingSources, []);
    assert.equal(options?.permissionMode, 'default');
    assert.equal(options?.env?.ANTHROPIC_API_KEY, undefined, 'the credential env is stripped');
    assert.ok(options?.canUseTool !== undefined);
  });
});

describe('EditService.start', () => {
  let dir = '';
  let root = '';
  let outside = '';
  let target = '';

  beforeEach(() => {
    dir = realPathOf(mkdtempSync(join(tmpdir(), 'nvime-edit-')));
    root = join(dir, 'proj');
    outside = join(dir, 'elsewhere');
    mkdirSync(root, { recursive: true });
    mkdirSync(outside, { recursive: true });
    target = join(root, 'queue.py');
    writeFileSync(target, 'def drain():\n    pass\n');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  const start = (service: EditService, id = 1) =>
    service.start(id, { root, prompt: 'guard the drain', scope: { kind: 'file', path: target } });

  it('pushes the exact mutation once the tool that made it has finished', async () => {
    const denied: string[] = [];
    const h = harness([
      { yield: frames.init() },
      { yield: frames.delta('adding a lock') },
      { yield: frames.toolUse('t1', 'Edit', { file_path: target }) },
      toolStep('t1', 'Edit', { file_path: target }, () => writeFileSync(target, 'def drain():\n    lock()\n'), denied),
      { yield: frames.toolResult('t1') },
      { yield: frames.success('added a lock') },
    ]);
    const done = await start(h.service);
    assert.deepEqual(denied, [], 'a write under the root needs no approval');

    const applied = h.events.filter((e) => e.event === 'edit.applied');
    assert.equal(applied.length, 1);
    assert.deepEqual(applied[0]?.params.before, { kind: 'text', text: 'def drain():\n    pass\n' });
    assert.deepEqual(applied[0]?.params.after, { kind: 'text', text: 'def drain():\n    lock()\n' });
    assert.equal(applied[0]?.params.path, target);
    assert.equal(applied[0]?.params.id, 1, 'and it is attributed to the request that caused it');
    assert.equal(done.changes.length, 1);
  });

  it('emits the activity line before the mutation it produced', async () => {
    const denied: string[] = [];
    const h = harness([
      { yield: frames.init() },
      { yield: frames.toolUse('t1', 'Edit', { file_path: target }) },
      toolStep('t1', 'Edit', { file_path: target }, () => writeFileSync(target, 'changed\n'), denied),
      { yield: frames.toolResult('t1') },
      { yield: frames.success('ok') },
    ]);
    await start(h.service);
    const order = h.events.map((e) => e.event);
    assert.deepEqual(order, ['edit.started', 'edit.tool', 'edit.applied']);
  });

  it('says nothing when the tool changed nothing', async () => {
    const denied: string[] = [];
    const h = harness([
      { yield: frames.init() },
      { yield: frames.toolUse('t1', 'Edit', { file_path: target }) },
      toolStep('t1', 'Edit', { file_path: target }, () => {}, denied),
      { yield: frames.toolResult('t1') },
      { yield: frames.success('nothing to do') },
    ]);
    const done = await start(h.service);
    assert.equal(h.events.filter((e) => e.event === 'edit.applied').length, 0);
    assert.equal(done.changes.length, 0);
  });

  it('records a file the agent created, with an absent before', async () => {
    const denied: string[] = [];
    const created = join(root, 'new.py');
    const h = harness([
      { yield: frames.init() },
      { yield: frames.toolUse('t1', 'Write', { file_path: created }) },
      toolStep('t1', 'Write', { file_path: created }, () => writeFileSync(created, 'fresh\n'), denied),
      { yield: frames.toolResult('t1') },
      { yield: frames.success('created it') },
    ]);
    const done = await start(h.service);
    assert.deepEqual(done.changes[0]?.before, { kind: 'absent' });
    assert.deepEqual(done.changes[0]?.after, { kind: 'text', text: 'fresh\n' });
  });

  it('still reports a mutation whose tool result never arrived', async () => {
    const denied: string[] = [];
    const h = harness([
      { yield: frames.init() },
      { yield: frames.toolUse('t1', 'Edit', { file_path: target }) },
      toolStep('t1', 'Edit', { file_path: target }, () => writeFileSync(target, 'orphaned\n'), denied),
      { yield: frames.success('done') },
    ]);
    const done = await start(h.service);
    assert.equal(done.changes.length, 1, 'the run must not end with a buffer nobody was told about');
    assert.deepEqual(done.changes[0]?.after, { kind: 'text', text: 'orphaned\n' });
  });

  it('refuses a second run for the same project', async () => {
    const h = harness([{ yield: frames.init() }, { yield: frames.success('done') }]);
    const first = start(h.service, 1);
    await assert.rejects(() => start(h.service, 2), (cause: ProtocolError) => cause.code === 'busy');
    await first;
  });

  it('carries the follow-up session id into the resumed run', async () => {
    const h = harness([{ yield: frames.init() }, { yield: frames.success('done') }]);
    await h.service.start(1, { root, prompt: 'again', scope: { kind: 'project' }, sessionId: SESSION });
    assert.equal(h.calls[0]?.options.resume, SESSION);
  });
});

describe('EditService: approvals', () => {
  let dir = '';
  let root = '';
  let outside = '';

  beforeEach(() => {
    dir = realPathOf(mkdtempSync(join(tmpdir(), 'nvime-edit-approval-')));
    root = join(dir, 'proj');
    outside = join(dir, 'elsewhere');
    mkdirSync(root, { recursive: true });
    mkdirSync(outside, { recursive: true });
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  /** Answers every approval the run raises, the way the plugin's float does. */
  const answering = (allow: boolean) => (event: Event, service: EditService) => {
    if (event.event !== 'edit.approval') return;
    setImmediate(() => service.answer(String(event.params.approvalId), allow));
  };

  const outsideFile = () => join(outside, 'secret.txt');

  function run(steps: Step[], options: Parameters<typeof harness>[1]): Promise<unknown> {
    const h = harness(steps, options);
    return h.service
      .start(1, { root, prompt: 'do it', scope: { kind: 'project' } })
      .then(() => h);
  }

  it('blocks a write outside the root until the editor allows it', async () => {
    const denied: string[] = [];
    const path = outsideFile();
    const h = (await run(
      [
        { yield: frames.init() },
        { yield: frames.toolUse('t1', 'Write', { file_path: path }) },
        toolStep('t1', 'Write', { file_path: path }, () => writeFileSync(path, 'allowed\n'), denied),
        { yield: frames.toolResult('t1') },
        { yield: frames.success('ok') },
      ],
      { onEvent: answering(true) },
    )) as Harness;
    assert.deepEqual(denied, []);
    assert.equal(readFileSync(path, 'utf8'), 'allowed\n');
    const ask = h.events.find((e) => e.event === 'edit.approval');
    assert.match(String(ask?.params.reason), /outside the project root/);
    assert.equal(h.events.find((e) => e.event === 'edit.approval_settled')?.params.allowed, true);
  });

  it('refuses the write when the editor says no, and the file stays untouched', async () => {
    const denied: string[] = [];
    const path = outsideFile();
    await run(
      [
        { yield: frames.init() },
        { yield: frames.toolUse('t1', 'Write', { file_path: path }) },
        toolStep('t1', 'Write', { file_path: path }, () => writeFileSync(path, 'sneaked in\n'), denied),
        { yield: frames.success('ok') },
      ],
      { onEvent: answering(false) },
    );
    assert.equal(denied.length, 1);
    assert.match(denied[0] ?? '', /denied in the editor/);
    assert.throws(() => readFileSync(path, 'utf8'), /ENOENT/);
  });

  it('denies a shell command nobody answers for', async () => {
    const denied: string[] = [];
    let ran = false;
    const h = (await run(
      [
        { yield: frames.init() },
        { yield: frames.toolUse('t1', 'Bash', { command: 'rm -rf /' }) },
        toolStep('t1', 'Bash', { command: 'rm -rf /' }, () => {
          ran = true;
        }, denied),
        { yield: frames.success('ok') },
      ],
      { approvalTimeoutMs: 30 },
    )) as Harness;
    assert.equal(ran, false, 'an unanswered ask must never fall through to the tool');
    assert.match(denied[0] ?? '', /no answer from the editor/);
    assert.match(String(h.events.find((e) => e.event === 'edit.approval')?.params.reason), /shell command/);
  });

  it('reports an answer to an approval that is no longer parked', async () => {
    const h = harness([{ yield: frames.init() }, { yield: frames.success('ok') }]);
    assert.equal(h.service.answer('r1:t1', true), false);
  });
});

describe('EditService.listChanges', () => {
  let dir = '';
  let root = '';
  let target = '';

  beforeEach(() => {
    dir = realPathOf(mkdtempSync(join(tmpdir(), 'nvime-edit-log-')));
    root = join(dir, 'proj');
    mkdirSync(root, { recursive: true });
    target = join(root, 'a.txt');
    writeFileSync(target, 'one\n');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('keeps the log across runs and filters it by run', async () => {
    const denied: string[] = [];
    const script = (id: string, text: string): Step[] => [
      { yield: frames.init() },
      { yield: frames.toolUse(id, 'Edit', { file_path: target }) },
      toolStep(id, 'Edit', { file_path: target }, () => writeFileSync(target, text), denied),
      { yield: frames.toolResult(id) },
      { yield: frames.success('ok') },
    ];
    // One service, two turns: the script is swapped between them.
    let steps: Step[] = script('t1', 'two\n');
    const service = new EditService({
      sdk: {
        query: ({ options }) =>
          (async function* () {
            for (const step of steps) {
              if ('yield' in step) yield step.yield;
              else await step.act(options as Options);
            }
          })(),
      },
      claudePath: '/usr/bin/claude',
      env: { PATH: '/usr/bin' },
      emit: () => {},
    });

    const first = await service.start(1, { root, prompt: 'a', scope: { kind: 'project' } });
    steps = script('t2', 'three\n');
    const second = await service.start(2, { root, prompt: 'b', scope: { kind: 'project' } });

    const all = service.listChanges(root);
    assert.equal(all.length, 2);
    assert.deepEqual(
      all.map((change: AppliedChange) => change.after),
      [
        { kind: 'text', text: 'two\n' },
        { kind: 'text', text: 'three\n' },
      ],
    );
    assert.equal(service.listChanges(root, first.runId).length, 1);
    assert.equal(service.listChanges(root, second.runId)[0]?.runId, second.runId);
    assert.equal(service.listChanges(root, undefined, 1).length, 1, 'a limit takes the most recent');
    assert.deepEqual(service.listChanges(dir), [], 'and another project sees none of it');
  });
});

describe('composeEditPrompt', () => {
  it('names the file and forbids a printed patch', () => {
    const prompt = composeEditPrompt('add a lock', { kind: 'file', path: '/work/proj/queue.py' }, '/work/proj');
    assert.match(prompt, /in queue\.py/);
    assert.match(prompt, /do not print a patch/);
    assert.match(prompt, /add a lock$/);
  });

  it('attaches the selection it is scoped to', () => {
    const prompt = composeEditPrompt(
      'use a with-block',
      { kind: 'selection', path: '/work/proj/queue.py', startLine: 139, endLine: 141, text: 'for x in y:' },
      '/work/proj',
    );
    assert.match(prompt, /lines 139-141/);
    assert.match(prompt, /<context file="queue\.py" lines="139-141">/);
    assert.match(prompt, /for x in y:/);
  });
});

describe('parseScope', () => {
  it('defaults to the whole project', () => {
    assert.deepEqual(parseScope(undefined), { kind: 'project' });
    assert.deepEqual(parseScope(null), { kind: 'project' });
  });

  it('accepts a file and a selection', () => {
    assert.deepEqual(parseScope({ kind: 'file', path: '/a' }), { kind: 'file', path: '/a' });
    assert.deepEqual(parseScope({ kind: 'selection', path: '/a', startLine: 1, endLine: 2, text: 'x' }), {
      kind: 'selection',
      path: '/a',
      startLine: 1,
      endLine: 2,
      text: 'x',
    });
  });

  it('rejects a scope it cannot act on', () => {
    assert.throws(() => parseScope({ kind: 'file' }), /scope\.path/);
    assert.throws(() => parseScope({ kind: 'nonsense' }), /is not a scope/);
    assert.throws(() => parseScope({ kind: 'selection', path: '/a', startLine: 0, endLine: 2 }), /startLine/);
    assert.throws(() => parseScope([]), /must be an object/);
  });
});
