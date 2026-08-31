import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { BIG_AUTO_ALLOWED, BigService, type SessionView } from '../src/big.js';
import { BigStore } from '../src/bigstore.js';
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
  tool: (id: string, name: string, input: Record<string, unknown>) =>
    ({
      type: 'assistant',
      message: { content: [{ type: 'tool_use', id, name, input }] },
    }) as unknown as SDKMessage,
  result: (text: string, structured?: unknown, sessionId = SESSION) =>
    ({
      type: 'result',
      subtype: 'success',
      is_error: false,
      result: text,
      structured_output: structured,
      session_id: sessionId,
      num_turns: 1,
      total_cost_usd: 0.01,
      usage: { input_tokens: 10, output_tokens: 4 },
    }) as unknown as SDKMessage,
};

/** One scripted agent turn: what it does, then what it yields. */
interface Turn {
  act?: (options: Options) => Promise<void>;
  frames: SDKMessage[];
}

interface Event {
  event: string;
  params: Record<string, unknown>;
}

let root = '';
let repo = '';
let store: BigStore;
let service: BigService;
let events: Event[];
let calls: Array<{ prompt: string; options: Options }>;
let turns: Turn[];

function gitInit(dir: string): void {
  mkdirSync(dir, { recursive: true });
  const run = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'pipe' });
  };
  run('init', '-q', '-b', 'main');
  run('config', 'user.email', 'nvime@example.invalid');
  run('config', 'user.name', 'nvime tests');
  writeFileSync(join(dir, 'tool.py'), 'def main():\n    print("hi")\n');
  run('add', '-A');
  run('commit', '-qm', 'initial');
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-bigsvc-'));
  repo = join(root, 'repo');
  gitInit(repo);
  store = new BigStore(join(root, 'store'));
  events = [];
  calls = [];
  turns = [];
  service = new BigService({
    sdk: {
      query: ({ prompt, options }: { prompt: string; options?: Options }) => {
        assert.ok(options !== undefined, 'the service always builds options');
        calls.push({ prompt, options });
        const turn = turns.shift();
        assert.ok(turn !== undefined, `no scripted turn for: ${prompt.slice(0, 60)}`);
        return (async function* () {
          if (turn.act !== undefined) await turn.act(options);
          for (const frame of turn.frames) yield frame;
        })();
      },
    },
    store,
    claudePath: '/usr/bin/true',
    env: { PATH: process.env.PATH },
    emit: (event, params) => events.push({ event, params }),
  });
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

const SPEC = {
  goal: 'add a --version flag',
  scope: ['tool.py'],
  approach: 'argparse',
  acceptance: ['tool.py --version prints the version'],
  outOfScope: ['packaging'],
};

/** Runs the tool the way the CLI does: ask `canUseTool`, act only if allowed. */
async function useTool(
  options: Options,
  name: string,
  input: Record<string, unknown>,
  perform: () => void,
  denied: string[] = [],
): Promise<void> {
  const decide = options.canUseTool;
  assert.ok(decide !== undefined, 'a build turn must install a permission callback');
  const decision = await decide(name, input, {
    signal: new AbortController().signal,
    toolUseID: 't1',
    requestId: 'r1',
  });
  if (decision !== null && decision.behavior === 'allow') perform();
  else denied.push(decision === null ? 'null' : decision.message);
}

/** Drafts a session, answers intake once with a ready spec, and approves it. */
async function approved(): Promise<SessionView> {
  const created = service.create(repo, 'version flag');
  turns.push({ frames: [frames.init(), frames.result('spec', { ready: true, message: 'here it is', spec: SPEC })] });
  await service.intake(1, { root: repo, id: created.id, message: 'add a --version flag' });
  return service.approve(repo, created.id);
}

/** A build that writes one file, then a triage turn returning `structured`. */
function scriptBuild(structured: unknown, write = 'def main():\n    print("v1")\n'): void {
  turns.push({
    act: async (options) => {
      const target = join(String(options.cwd), 'tool.py');
      await useTool(options, 'Write', { file_path: target, content: write }, () => writeFileSync(target, write));
    },
    frames: [frames.init(), frames.delta('working'), frames.result('built it')],
  });
  turns.push({ frames: [frames.init(), frames.result('triaged', structured)] });
}

describe('big intake', () => {
  it('records the exchange and keeps the spec the agent played back', async () => {
    const created = service.create(repo, 'version flag');
    turns.push({ frames: [frames.init(), frames.result('spec', { ready: true, message: 'playback', spec: SPEC })] });
    const view = await service.intake(1, { root: repo, id: created.id, message: 'add a --version flag' });
    assert.deepEqual(view.spec, SPEC);
    assert.deepEqual(
      view.conversation.map((turn) => [turn.role, turn.text]),
      [
        ['user', 'add a --version flag'],
        ['agent', 'playback'],
      ],
    );
    assert.match(calls[0]?.prompt ?? '', /add a --version flag/);
    assert.deepEqual(calls[0]?.options.allowedTools, [...BIG_AUTO_ALLOWED]);
    const tools = calls[0]?.options.tools;
    assert.ok(Array.isArray(tools) && !tools.includes('Write'), 'intake may not write');
  });

  it('resumes the same intake session on the next message', async () => {
    const created = service.create(repo, 'version flag');
    turns.push({ frames: [frames.init(), frames.result('q1', { ready: false, message: 'which file?' })] });
    await service.intake(1, { root: repo, id: created.id, message: 'a flag' });
    turns.push({ frames: [frames.init(), frames.result('q2', { ready: true, message: 'ok', spec: SPEC })] });
    const view = await service.intake(2, { root: repo, id: created.id, message: 'tool.py' });
    assert.equal(calls[1]?.options.resume, SESSION);
    assert.equal(calls[1]?.prompt, 'tool.py', 'a follow-up rides the session, not the opening instruction');
    assert.equal(view.display, 'drafting');
  });

  it('invents no spec when the structured answer is unusable', async () => {
    const created = service.create(repo, 'version flag');
    turns.push({ frames: [frames.init(), frames.result('prose only', 'not an object')] });
    const view = await service.intake(1, { root: repo, id: created.id, message: 'a flag' });
    assert.equal(view.spec, null);
    assert.equal(view.conversation[1]?.text, 'prose only');
  });

  it('refuses more intake once the spec is approved', async () => {
    const view = await approved();
    await assert.rejects(
      () => service.intake(9, { root: repo, id: view.id, message: 'more' }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'bad_request',
    );
  });
});

describe('big worktree lifecycle', () => {
  it('creates a detached worktree outside the repo at the recorded base commit', async () => {
    const view = await approved();
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
    assert.equal(view.state, 'building');
    assert.equal(view.worktree?.baseCommit, head);
    assert.equal(view.worktree?.baseBranch, 'main');
    assert.ok(view.worktree !== null && existsSync(join(view.worktree.path, 'tool.py')));
    assert.ok(!view.worktree.path.startsWith(repo + '/'), 'a worktree inside the repo appears in its own diff');
    const inside = execFileSync('git', ['-C', view.worktree.path, 'rev-parse', '--abbrev-ref', 'HEAD'], {
      encoding: 'utf8',
    }).trim();
    assert.equal(inside, 'HEAD', 'detached, so no branch the user might be on is moved');
  });

  it('refuses to approve a spec that does not exist yet', async () => {
    const created = service.create(repo, 'no spec');
    await assert.rejects(
      () => service.approve(repo, created.id),
      (error: unknown) => error instanceof ProtocolError && /no spec/.test(error.message),
    );
  });

  it('discards the worktree and the record together', async () => {
    const view = await approved();
    const path = view.worktree?.path ?? '';
    assert.deepEqual(await service.discard(repo, view.id), { discarded: true });
    assert.equal(existsSync(path), false);
    assert.equal(store.read(repo, view.id), null);
  });
});

describe('big build and triage', () => {
  it('captures the real diff and groups it into the threads triage asked for', async () => {
    const approvedView = await approved();
    scriptBuild({
      blocks: [
        { title: 'version flag', hunkIds: ['h1.1'], substantial: true, rationale: 'behavior' },
      ],
    });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(view.display, 'reviewing');
    assert.equal(view.hasDiff, true);
    assert.equal(view.blocks.length, 1);
    assert.deepEqual(view.blocks[0]?.files, ['tool.py']);
    assert.equal(view.counts.open, 1);
    const diff = service.diff(repo, view.id)?.text ?? '';
    assert.match(diff, /\+ {4}print\("v1"\)/);
    assert.deepEqual(
      view.transitions.map((entry) => entry.state),
      ['drafting', 'building', 'triaging', 'reviewing'],
    );
  });

  it('falls back to one block per file when triage answers with garbage', async () => {
    const approvedView = await approved();
    turns.push({
      act: async (options) => {
        const dir = String(options.cwd);
        writeFileSync(join(dir, 'tool.py'), 'def main():\n    print("v1")\n');
        writeFileSync(join(dir, 'version.py'), 'VERSION = "1.0"\n');
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: [frames.init(), frames.result('nonsense', { totally: 'wrong' })] });
    const view = await service.build(2, { root: repo, id: approvedView.id });

    assert.equal(view.blocks.length, 2, 'one block per changed file');
    assert.ok(view.blocks.every((block) => block.substantial && block.state === 'open'));
    const covered = view.blocks.flatMap((block) => block.hunkIds).sort();
    const total = new Set(covered);
    assert.equal(covered.length, total.size, 'no hunk is claimed twice');
    assert.equal(total.size, 2, 'every hunk of both files is in a thread');
    assert.ok(
      events.some((entry) => entry.event === 'big.notice' && /fell back/.test(String(entry.params.text))),
      'the fallback is reported, not hidden',
    );
  });

  it('shows an untracked file the build created', async () => {
    const approvedView = await approved();
    turns.push({
      act: async (options) => {
        writeFileSync(join(String(options.cwd), 'brand-new.py'), 'x = 1\n');
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: [frames.init(), frames.result('t', { blocks: [] })] });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.deepEqual(view.blocks.map((block) => block.files), [['brand-new.py']]);
  });

  it('stays honest when the build changed nothing', async () => {
    const approvedView = await approved();
    turns.push({ frames: [frames.init(), frames.result('nothing to do')] });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(view.blocks.length, 0);
    assert.equal(view.display, 'reviewing', 'never mergeable on an empty change');
    assert.match(view.transitions[view.transitions.length - 1]?.note ?? '', /changed nothing/);
  });

  it('refuses a write outside the worktree and lets the build carry on', async () => {
    const approvedView = await approved();
    const outside = join(root, 'escape.txt');
    const denied: string[] = [];
    turns.push({
      act: async (options) => {
        await useTool(options, 'Write', { file_path: outside, content: 'nope' }, () => {
          writeFileSync(outside, 'nope');
        }, denied);
        const inside = join(String(options.cwd), 'tool.py');
        await useTool(options, 'Write', { file_path: inside, content: 'ok\n' }, () => writeFileSync(inside, 'ok\n'));
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: [frames.init(), frames.result('t', { blocks: [] })] });
    await service.build(2, { root: repo, id: approvedView.id });

    assert.equal(existsSync(outside), false, 'the write never happened');
    assert.equal(denied.length, 1);
    assert.match(denied[0] ?? '', /only write inside its own worktree/);
    assert.ok(events.some((entry) => entry.event === 'big.denied'));
  });

  it('lets the build run a shell command without asking', async () => {
    const approvedView = await approved();
    let allowed = false;
    turns.push({
      act: async (options) => {
        await useTool(options, 'Bash', { command: 'npm test' }, () => {
          allowed = true;
        });
      },
      frames: [frames.init(), frames.result('ran the tests')],
    });
    turns.push({ frames: [frames.init(), frames.result('t', { blocks: [] })] });
    await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(allowed, true, 'a build must be able to run the project tests');
  });
});

describe('big review threads', () => {
  it('carries a cleared thread forward across a revision', async () => {
    const approvedView = await approved();
    turns.push({
      act: async (options) => {
        const dir = String(options.cwd);
        writeFileSync(join(dir, 'tool.py'), 'def main():\n    print("v1")\n');
        writeFileSync(join(dir, 'notes.md'), 'notes\n');
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({
      frames: [
        frames.init(),
        frames.result('t', {
          blocks: [
            { title: 'behavior', hunkIds: ['h1.1'], substantial: true, rationale: '' },
            { title: 'notes', hunkIds: ['h2.1'], substantial: false, rationale: 'docs' },
          ],
        }),
      ],
    });
    const built = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(built.blocks[1]?.state, 'resolved');

    // The revision touches only the substantial file; the notes hunk is byte
    // identical, so its cleared verdict must survive the re-triage.
    turns.push({
      act: async (options) => {
        writeFileSync(join(String(options.cwd), 'tool.py'), 'def main():\n    print("v2")\n');
      },
      frames: [frames.init(), frames.result('revised')],
    });
    turns.push({
      frames: [
        frames.init(),
        frames.result('t', {
          blocks: [
            { title: 'behavior', hunkIds: ['h1.1'], substantial: true, rationale: '' },
            { title: 'notes', hunkIds: ['h2.1'], substantial: false, rationale: 'docs' },
          ],
        }),
      ],
    });
    const revised = await service.revise(3, {
      root: repo,
      id: approvedView.id,
      blockId: 'b1',
      comment: 'use v2 instead',
    });
    assert.equal(revised.blocks[1]?.state, 'resolved', 'unchanged trivia stays cleared');
    assert.equal(revised.blocks[0]?.state, 'open', 'the changed hunk is unreviewed again');
    assert.match(service.diff(repo, revised.id)?.text ?? '', /v2/);
    assert.equal(calls[3]?.options.resume, SESSION, 'the revision continues the build session');
  });

  it('re-opens an auto-resolved thread and refuses to clear a substantial one by hand', async () => {
    const approvedView = await approved();
    scriptBuild({
      blocks: [
        { title: 'behavior', hunkIds: ['h1.1'], substantial: true, rationale: '' },
      ],
    });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.throws(
      () => service.toggleBlock(repo, view.id, 'b1', true),
      (error: unknown) => error instanceof ProtocolError && /review gate/.test(error.message),
    );
    const reopened = service.toggleBlock(repo, view.id, 'b1', false);
    assert.equal(reopened.blocks[0]?.state, 'open');
    assert.throws(() => service.toggleBlock(repo, view.id, 'nope', false), ProtocolError);
  });
});

describe('big state honesty', () => {
  it('reports a build nobody is driving as detached', async () => {
    const view = await approved();
    const reopened = service.open(repo, view.id);
    assert.equal(reopened.display, 'building');
    assert.equal(reopened.detached, true, 'the sidecar that was building it is gone');
    assert.equal(reopened.hasDiff, false);
  });

  it('sends a session whose worktree was deleted back to drafting', async () => {
    const view = await approved();
    rmSync(view.worktree?.path ?? '', { recursive: true, force: true });
    const reopened = service.open(repo, view.id);
    assert.equal(reopened.display, 'drafting');
    assert.equal(reopened.worktree, null);
    assert.deepEqual(reopened.spec, SPEC, 'the spec survives so it can be rebuilt');
    await assert.rejects(
      () => service.build(9, { root: repo, id: view.id }),
      (error: unknown) => error instanceof ProtocolError && /approve the spec/.test(error.message),
    );
  });

  it('never claims a review is ready when the captured diff is gone', async () => {
    const approvedView = await approved();
    scriptBuild({ blocks: [{ title: 'x', hunkIds: ['h1.1'], substantial: true, rationale: '' }] });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(view.display, 'reviewing');
    rmSync(store.diffPathFor(repo, view.id));
    const reopened = service.open(repo, view.id);
    assert.equal(reopened.display, 'building');
    assert.deepEqual(reopened.blocks, []);
  });

  it('resumes an interrupted build in the same worktree instead of starting over', async () => {
    const approvedView = await approved();
    scriptBuild({ blocks: [] }, 'def main():\n    print("half")\n');
    await service.build(2, { root: repo, id: approvedView.id });
    assert.match(calls[1]?.prompt ?? '', /Implement the following change completely/);
    assert.equal(calls[1]?.options.resume, undefined, 'the first build starts a session');

    scriptBuild({ blocks: [] }, 'def main():\n    print("done")\n');
    await service.build(3, { root: repo, id: approvedView.id });
    assert.equal(calls[3]?.options.resume, SESSION, 'the second run continues the same build session');
    assert.match(calls[3]?.prompt ?? '', /previous run was interrupted/);
    assert.equal(calls[3]?.options.cwd, approvedView.worktree?.path);
    assert.match(service.diff(repo, approvedView.id)?.text ?? '', /print\("done"\)/);
  });

  it('lists sessions with the state the picker shows', async () => {
    const view = await approved();
    const listed = service.list(repo);
    assert.equal(listed.length, 1);
    assert.equal(listed[0]?.title, 'version flag');
    assert.equal(listed[0]?.display, 'building');
    assert.equal(listed[0]?.detached, true);
    assert.deepEqual(service.list(join(root, 'elsewhere')), []);
    assert.equal(store.read(repo, view.id)?.id, view.id);
  });

  it('is mergeable only once every thread is cleared', async () => {
    const approvedView = await approved();
    scriptBuild({ blocks: [{ title: 'docs', hunkIds: ['h1.1'], substantial: false, rationale: 'comments' }] });
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(view.display, 'mergeable');
    assert.equal(service.toggleBlock(repo, view.id, 'b1', false).display, 'reviewing');
  });

  it('refuses a second run on a session already running', async () => {
    const approvedView = await approved();
    let rejected: unknown = null;
    turns.push({
      act: async () => {
        rejected = await service.build(99, { root: repo, id: approvedView.id }).catch((error: unknown) => error);
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: [frames.init(), frames.result('t', { blocks: [] })] });
    await service.build(2, { root: repo, id: approvedView.id });
    assert.ok(rejected instanceof ProtocolError && rejected.code === 'busy');
  });
});

describe('big session store on disk', () => {
  it('keeps the record where a later editor can find it', async () => {
    const view = await approved();
    const record = JSON.parse(readFileSync(join(store.dirFor(repo, view.id), 'session.json'), 'utf8')) as {
      state: string;
      transitions: unknown[];
    };
    assert.equal(record.state, 'building');
    assert.equal(record.transitions.length, 2);
  });
});
