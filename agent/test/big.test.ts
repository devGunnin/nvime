import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { BIG_AUTO_ALLOWED, BigService, buildWriteBoundary, type SessionView } from '../src/big.js';
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

/**
 * One scripted agent turn: what it does, then what it yields. `frames` may be a
 * function of the prompt, which is how a triage turn answers with the hunk ids
 * it was actually shown — they are content hashes, not positions.
 */
interface Turn {
  act?: (options: Options) => Promise<void>;
  frames: SDKMessage[] | ((prompt: string) => SDKMessage[]);
}

/** The hunks a triage prompt showed: `[<id>] <status> <path>`. */
function shownHunks(prompt: string): Array<{ id: string; file: string }> {
  return [...prompt.matchAll(/^\[(h[0-9a-f_]+)\] \S+ (.+)$/gm)].map((match) => ({
    id: match[1] ?? '',
    file: match[2] ?? '',
  }));
}

/**
 * A triage answer written in terms of the FILES the prompt showed. Hunk ids
 * are content hashes, so a test can neither spell them nor rely on their order.
 */
function triageByFile(groups: Array<{ title: string; files: string[]; substantial: boolean }>) {
  return (prompt: string): SDKMessage[] => {
    const shown = shownHunks(prompt);
    return [
      frames.init(),
      frames.result('triaged', {
        blocks: groups.map((group) => ({
          title: group.title,
          hunkIds: shown.filter((hunk) => group.files.includes(hunk.file)).map((hunk) => hunk.id),
          substantial: group.substantial,
          rationale: '',
        })),
      }),
    ];
  };
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
  writeFileSync(join(dir, 'README.md'), 'scratch\n');
  run('add', '-A');
  run('commit', '-qm', 'initial');
  writeFileSync(join(dir, 'tool.py'), 'def main():\n    print("hi")\n');
  run('add', '-A');
  run('commit', '-qm', 'add the tool');
}

/** One git command, trimmed. Used to check what the build did and did not do. */
function gitIn(dir: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim();
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
          for (const frame of typeof turn.frames === 'function' ? turn.frames(prompt) : turn.frames) yield frame;
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

/** A build that writes tool.py, then a triage turn grouping what it produced. */
function scriptBuild(
  groups: Array<{ title: string; substantial: boolean }>,
  write = 'def main():\n    print("v1")\n',
): void {
  turns.push({
    act: async (options) => {
      const target = join(String(options.cwd), 'tool.py');
      await useTool(options, 'Write', { file_path: target, content: write }, () => writeFileSync(target, write));
    },
    frames: [frames.init(), frames.delta('working'), frames.result('built it')],
  });
  turns.push({ frames: triageByFile(groups.map((group) => ({ ...group, files: ['tool.py'] }))) });
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

describe('big build isolation', () => {
  it('approves without a checkout, then builds in a clone at the recorded base', async () => {
    const view = await approved();
    const head = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim();
    assert.equal(view.state, 'building');
    assert.equal(view.worktree?.baseCommit, head);
    assert.equal(view.worktree?.baseBranch, 'main');
    // Approval runs under the editor's control deadline, so it does no
    // checkout at all; the clone is the build's first act.
    assert.equal(view.worktree?.ready, false);
    assert.equal(existsSync(view.worktree?.path ?? ''), false);

    scriptBuild([{ title: 'version flag', substantial: true }]);
    const built = await service.build(2, { root: repo, id: view.id });
    const clone = built.worktree?.path ?? '';
    assert.equal(built.worktree?.ready, true);
    assert.ok(existsSync(join(clone, 'tool.py')));
    assert.ok(!clone.startsWith(repo + '/'), 'a build tree inside the repo appears in its own diff');
    assert.equal(gitIn(clone, 'rev-parse', '--abbrev-ref', 'HEAD'), 'HEAD', 'detached, on the recorded commit');
    assert.equal(gitIn(clone, 'rev-parse', 'HEAD'), head);
  });

  it('gives the build its own ref store, so a git command in it cannot rewrite the operator branch', async () => {
    const view = await approved();
    const older = gitIn(repo, 'rev-parse', 'HEAD~1');
    const before = gitIn(repo, 'rev-parse', 'refs/heads/main');
    let inside = '';
    turns.push({
      act: async (options) => {
        // The reviewer's probe: one allowed Bash call, doing something an agent
        // "tidying git state" would do on its own.
        await useTool(options, 'Bash', { command: 'git update-ref refs/heads/main' }, () => {
          execFileSync('git', ['update-ref', 'refs/heads/main', older], { cwd: String(options.cwd) });
        });
        inside = gitIn(String(options.cwd), 'rev-parse', 'refs/heads/main');
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: triageByFile([]) });
    await service.build(2, { root: repo, id: view.id });

    assert.equal(inside, older, 'the build really did rewrite a branch — in its own repository');
    assert.equal(gitIn(repo, 'rev-parse', 'refs/heads/main'), before, "the operator's branch never moved");
    assert.equal(gitIn(repo, 'status', '--porcelain'), '', "and their working tree is untouched");
  });

  it('leaves no remote pointing back at the repository it was cloned from', async () => {
    const view = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    const built = await service.build(2, { root: repo, id: view.id });
    assert.equal(gitIn(built.worktree?.path ?? '', 'remote'), '', 'a push from the build must have nowhere to go');
  });

  it('registers nothing in the operator repo, so approving cannot break their other worktrees', async () => {
    // A worktree of theirs whose directory is temporarily away — an unmounted
    // volume, a locked home, a renamed path. A repo-global `worktree prune`
    // deletes its admin directory and leaves it unusable.
    const theirs = join(root, 'operator-wt');
    execFileSync('git', ['worktree', 'add', '-q', '--detach', theirs], { cwd: repo });
    const away = join(root, 'operator-wt-away');
    renameSync(theirs, away);

    const view = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    await service.build(2, { root: repo, id: view.id });

    renameSync(away, theirs);
    assert.equal(gitIn(theirs, 'rev-parse', '--is-inside-work-tree'), 'true', 'their worktree still works');
    const registered = gitIn(repo, 'worktree', 'list', '--porcelain');
    assert.ok(!registered.includes(store.root), 'the build is not a worktree of their repo at all');
  });

  it('refuses to approve a spec that does not exist yet', async () => {
    const created = service.create(repo, 'no spec');
    await assert.rejects(
      () => service.approve(repo, created.id),
      (error: unknown) => error instanceof ProtocolError && /no spec/.test(error.message),
    );
  });

  it('discards the clone and the record together', async () => {
    const view = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    const built = await service.build(2, { root: repo, id: view.id });
    const path = built.worktree?.path ?? '';
    assert.equal(existsSync(path), true);
    assert.deepEqual(await service.discard(repo, view.id), { discarded: true });
    assert.equal(existsSync(path), false);
    assert.equal(store.read(repo, view.id), null);
  });

  it('re-approves a session whose build clone vanished before any diff was captured', async () => {
    // Nothing was ever captured here (the clone is marked built by hand, never
    // actually run through `build`), so there is no finished review to keep —
    // this is still the "approve again to rebuild" path.
    const first = await approved();
    const worktreePath = first.worktree?.path ?? '';
    mkdirSync(join(worktreePath, '.git'), { recursive: true });
    const session = store.require(repo, first.id);
    if (session.worktree !== null) session.worktree.ready = true;
    store.save(session);
    rmSync(worktreePath, { recursive: true, force: true });
    assert.equal(service.open(repo, first.id).display, 'drafting');

    const second = await service.approve(repo, first.id);
    assert.equal(second.display, 'building');
    scriptBuild([{ title: 'x', substantial: true }]);
    const rebuilt = await service.build(4, { root: repo, id: first.id });
    assert.ok(rebuilt.worktree !== null && existsSync(join(rebuilt.worktree.path, 'tool.py')));
  });
});

describe('big build and triage', () => {
  it('captures the real diff and groups it into the threads triage asked for', async () => {
    const approvedView = await approved();
    scriptBuild([{ title: 'version flag', substantial: true }]);
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
      frames: triageByFile([
        { title: 'behavior', files: ['tool.py'], substantial: true },
        { title: 'notes', files: ['notes.md'], substantial: false },
      ]),
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
      frames: triageByFile([
        { title: 'behavior', files: ['tool.py'], substantial: true },
        { title: 'notes', files: ['notes.md'], substantial: false },
      ]),
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
    scriptBuild([{ title: 'behavior', substantial: true }]);
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.throws(
      () => service.toggleBlock(repo, view.id, 'b1', true),
      (error: unknown) => error instanceof ProtocolError && /review gate/.test(error.message),
    );
    const reopened = service.toggleBlock(repo, view.id, 'b1', false);
    assert.equal(reopened.blocks[0]?.state, 'open');
    assert.throws(() => service.toggleBlock(repo, view.id, 'nope', false), ProtocolError);
  });

  it('re-opens content a later triage promotes to substantial, however it was cleared before', async () => {
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
      frames: triageByFile([
        { title: 'behavior', files: ['tool.py'], substantial: true },
        { title: 'notes', files: ['notes.md'], substantial: false },
      ]),
    });
    const built = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(built.blocks[1]?.state, 'resolved', 'trivia auto-resolved in round 1');

    // notes.md is untouched by the revision, but triage corrects its own
    // rating. `mergeable` is built on `substantial`, so a thread that arrives
    // resolved here is a thread the review gate never saw.
    turns.push({
      act: async (options) => {
        writeFileSync(join(String(options.cwd), 'tool.py'), 'def main():\n    print("v2")\n');
      },
      frames: [frames.init(), frames.result('revised')],
    });
    turns.push({
      frames: triageByFile([
        { title: 'behavior', files: ['tool.py'], substantial: true },
        { title: 'notes', files: ['notes.md'], substantial: true },
      ]),
    });
    const revised = await service.revise(3, {
      root: repo,
      id: approvedView.id,
      blockId: 'b1',
      comment: 'use v2',
    });
    assert.equal(revised.blocks[1]?.substantial, true);
    assert.equal(revised.blocks[1]?.state, 'open', 'nobody defended it, so it must not arrive cleared');
    assert.notEqual(revised.display, 'mergeable');
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

  it('keeps a finished review readable when only the build clone is gone, and refuses its clone-only actions', async () => {
    const approvedView = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    const built = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(built.display, 'reviewing');
    rmSync(built.worktree?.path ?? '', { recursive: true, force: true });

    const reopened = service.open(repo, built.id);
    assert.equal(reopened.display, 'reviewing', 'the captured diff still verifies, so the review survives');
    assert.equal(reopened.worktree, null, 'the clone itself, and only it, is gone');
    assert.equal(reopened.hasDiff, true);
    assert.deepEqual(
      reopened.blocks.map((block) => block.id),
      built.blocks.map((block) => block.id),
      'the triaged threads are untouched',
    );
    assert.notEqual(service.diff(repo, built.id), null, 'the diff still renders, read-only');

    await assert.rejects(
      () => service.revise(9, { root: repo, id: built.id, blockId: reopened.blocks[0]?.id ?? '', comment: 'x' }),
      (error: unknown) => error instanceof ProtocolError && /no build clone to revise/.test(error.message),
    );
    await assert.rejects(
      () => service.build(10, { root: repo, id: built.id }),
      (error: unknown) => error instanceof ProtocolError && /build clone is gone/.test(error.message),
    );
  });

  it('never claims a review is ready when the captured diff is gone', async () => {
    const approvedView = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    const view = await service.build(2, { root: repo, id: approvedView.id });
    assert.equal(view.display, 'reviewing');
    rmSync(store.diffPathFor(repo, view.id));
    const reopened = service.open(repo, view.id);
    // Back to triaging, not to building: the build is done, only the split is
    // missing, so it is re-sorted rather than re-run.
    assert.equal(reopened.display, 'triaging');
    assert.deepEqual(reopened.blocks, []);
    assert.equal(reopened.hasDiff, false);
    assert.equal(service.diff(repo, view.id), null);
  });

  it('resumes an interrupted build in the same worktree instead of starting over', async () => {
    const approvedView = await approved();
    scriptBuild([], 'def main():\n    print("half")\n');
    await service.build(2, { root: repo, id: approvedView.id });
    assert.match(calls[1]?.prompt ?? '', /Implement the following change completely/);
    assert.equal(calls[1]?.options.resume, undefined, 'the first build starts a session');

    scriptBuild([], 'def main():\n    print("done")\n');
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
    scriptBuild([{ title: 'docs', substantial: false }]);
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

describe('a capture that does not finish', () => {
  /** Builds a.txt and b.txt, triaged into one thread per file. */
  async function twoFiles(): Promise<SessionView> {
    const view = await approved();
    turns.push({
      act: async (options) => {
        const dir = String(options.cwd);
        writeFileSync(join(dir, 'a.txt'), 'A change\n');
        writeFileSync(join(dir, 'b.txt'), 'B change\n');
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({
      frames: triageByFile([
        { title: 'A change', files: ['a.txt'], substantial: true },
        { title: 'B change', files: ['b.txt'], substantial: true },
      ]),
    });
    return service.build(2, { root: repo, id: view.id });
  }

  it('renders no threads at all rather than the previous build\'s over a newer diff', async () => {
    const built = await twoFiles();
    assert.equal(built.blocks.length, 2);

    // The revision adds a file ahead of b.txt and edits b.txt, then the triage
    // turn is stopped. Nothing may survive that describes the older build.
    turns.push({
      act: async (options) => {
        const dir = String(options.cwd);
        writeFileSync(join(dir, 'aaa.txt'), 'brand new secret\n');
        writeFileSync(join(dir, 'b.txt'), 'B changed again\n');
      },
      frames: [frames.init(), frames.result('revised')],
    });
    turns.push({
      act: async () => {
        throw new ProtocolError('cancelled', 'the big change was stopped');
      },
      frames: [],
    });
    await assert.rejects(
      () => service.revise(3, { root: repo, id: built.id, blockId: 'b1', comment: 'again' }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'cancelled',
    );

    const after = service.open(repo, built.id);
    assert.deepEqual(after.blocks, [], 'threads that describe a build nobody captured must not survive');
    assert.equal(after.hasDiff, false, 'and the review surface refuses to open');
    assert.equal(after.display, 'triaging', 'the build is done; only the split is missing');
    assert.equal(service.diff(repo, built.id), null, 'no diff is served that no threads describe');
  });

  it('re-triages the finished build instead of running the build agent again', async () => {
    const built = await twoFiles();
    turns.push({
      act: async () => {
        throw new ProtocolError('cancelled', 'stopped');
      },
      frames: [],
    });
    await assert.rejects(() => service.capture(3, { root: repo, id: built.id }), ProtocolError);
    assert.equal(service.open(repo, built.id).display, 'triaging');

    const before = calls.length;
    turns.push({
      frames: triageByFile([
        { title: 'both', files: ['a.txt', 'b.txt'], substantial: true },
      ]),
    });
    const recovered = await service.capture(4, { root: repo, id: built.id });
    assert.equal(calls.length - before, 1, 'one turn: the triage, not another build');
    assert.equal(recovered.display, 'reviewing');
    assert.deepEqual(recovered.blocks.map((block) => block.files), [['a.txt', 'b.txt']]);
    assert.equal(recovered.hasDiff, true);
  });
});

describe('two editors on one store', () => {
  /** A second sidecar, its own service and store, over the same directory. */
  function otherEditor(): BigService {
    return new BigService({
      sdk: { query: () => { throw new Error('the second editor never gets to run a turn'); } },
      store: new BigStore(store.root),
      claudePath: '/usr/bin/true',
      env: { PATH: process.env.PATH },
      emit: () => {},
    });
  }

  it('shows a live build as held elsewhere, and refuses to resume or discard it', async () => {
    const view = await approved();
    const other = otherEditor();
    let seen: SessionView | null = null;
    let build: unknown = null;
    let discard: unknown = null;
    turns.push({
      act: async () => {
        seen = other.open(repo, view.id);
        build = await other.build(50, { root: repo, id: view.id }).catch((error: unknown) => error);
        discard = await other.discard(repo, view.id).catch((error: unknown) => error);
      },
      frames: [frames.init(), frames.result('built it')],
    });
    turns.push({ frames: triageByFile([]) });
    await service.build(2, { root: repo, id: view.id });

    assert.ok(seen !== null);
    assert.equal((seen as SessionView).heldElsewhere, true);
    assert.equal((seen as SessionView).detached, false, '"nobody is driving it" would invite `resume`');
    assert.ok(build instanceof ProtocolError && build.code === 'busy', `second build: ${String(build)}`);
    assert.match(String((build as ProtocolError).message), /another editor/);
    assert.ok(discard instanceof ProtocolError && discard.code === 'busy', `discard: ${String(discard)}`);
    // The record the second editor tried to destroy is still the first one's.
    assert.notEqual(store.read(repo, view.id), null);
  });

  it('hands the session back once the run that held it is over', async () => {
    const view = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    await service.build(2, { root: repo, id: view.id });
    const other = otherEditor();
    assert.equal(other.open(repo, view.id).heldElsewhere, false, 'a released claim holds nothing');
    assert.deepEqual(await other.discard(repo, view.id), { discarded: true });
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

  it('refuses to remove a clone path a tampered record does not actually own', async () => {
    const view = await approved();
    scriptBuild([{ title: 'x', substantial: true }]);
    const built = await service.build(2, { root: repo, id: view.id });

    // Something outside the session's own clone directory — the exact shape
    // of directory `discard`/`#ensureClone` must never be pointed at.
    const decoy = join(root, 'decoy');
    mkdirSync(decoy, { recursive: true });
    writeFileSync(join(decoy, 'canary.txt'), 'do not delete me');

    const recordPath = join(store.dirFor(repo, built.id), 'session.json');
    const record = JSON.parse(readFileSync(recordPath, 'utf8')) as { worktree: { path: string } };
    record.worktree.path = decoy;
    writeFileSync(recordPath, JSON.stringify(record));

    await assert.rejects(() => service.discard(repo, built.id), ProtocolError);
    assert.equal(existsSync(decoy), true, 'the tampered path must survive a refused discard');
    assert.equal(existsSync(join(decoy, 'canary.txt')), true);
    assert.notEqual(store.read(repo, built.id), null, 'a refused discard must not destroy the record either');
  });
});

describe('the build write boundary', () => {
  it('fails closed when a build turn has no worktreeRoot, instead of installing no gate', () => {
    assert.throws(() => buildWriteBoundary(true, undefined), /worktreeRoot/);
  });

  it('resolves the real path for a build turn that has one', () => {
    const dir = mkdtempSync(join(tmpdir(), 'nvime-wtroot-'));
    assert.equal(buildWriteBoundary(true, dir), realpathSync(dir));
    rmSync(dir, { recursive: true, force: true });
  });

  it('installs nothing for a read-only turn, worktreeRoot or not', () => {
    assert.equal(buildWriteBoundary(false, undefined), null);
    assert.equal(buildWriteBoundary(false, '/some/path'), null);
  });
});

describe('a triage window too small for the whole diff', () => {
  it('tells the model how much was cut, notices it in the panel, and marks the leftover truthfully', async () => {
    const view = await approved();
    // Five new files, each comfortably past the 128KB triage window when
    // summed — big enough that some land past the cut without needing a
    // pathologically large single file.
    const names = ['big-a.txt', 'big-b.txt', 'big-c.txt', 'big-d.txt', 'big-e.txt'];
    turns.push({
      act: async (options) => {
        const dir = String(options.cwd);
        for (const name of names) {
          writeFileSync(join(dir, name), `${name}\n`.repeat(2500));
        }
      },
      frames: [frames.init(), frames.result('built it')],
    });
    // The triage turn only ever sees what fits; it groups exactly that into
    // one thread and never claims the hunks it was not shown.
    turns.push({ frames: triageByFile([{ title: 'shown', files: names, substantial: true }]) });

    const built = await service.build(2, { root: repo, id: view.id });

    const triagePrompt = calls[calls.length - 1]?.prompt ?? '';
    assert.match(triagePrompt, /Only \d+ of 5 hunks fit the size limit/, triagePrompt.slice(0, 200));

    assert.ok(
      events.some(
        (entry) => entry.event === 'big.notice' && /hunk\(s\) exceeded the triage window and were not shown/.test(String(entry.params.text)),
      ),
      'the panel must be told something was cut',
    );

    const unsorted = built.blocks.find((block) => block.title === 'unsorted');
    assert.ok(unsorted !== undefined, 'the hunks past the window must still land somewhere');
    assert.match(
      unsorted?.rationale ?? '',
      /exceeded the triage window and were not shown/,
      'the leftover thread must say what actually happened, not blame the model for hunks it never saw',
    );
    assert.equal(unsorted?.substantial, true, 'an unshown hunk is never auto-resolved');

    const covered = built.blocks.flatMap((block) => block.hunkIds);
    assert.equal(new Set(covered).size, covered.length, 'no hunk claimed twice');
    assert.equal(covered.length, 5, 'every file still lands in exactly one thread');
  });
});
