import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage, SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { BigService, type SessionView } from '../src/big.js';
import { BigStore } from '../src/bigstore.js';
import { DetachedService } from '../src/detached.js';
import { readEventsAfter, type RunEvent } from '../src/runlog.js';
import { socketPathFor } from '../src/runsock.js';
import type { FakeScript } from './fixtures/fake-runner.js';
import { configureGitIdentity } from './fixtures/git-identity.js';

/**
 * The detached runner, driven the way the sidecar drives it: a real second
 * process, spawned detached with its stdio on disk, holding the session claim
 * and serving a control socket. Only the agent inside it is scripted.
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const FAKE_RUNNER = join(HERE, 'fixtures', 'fake-runner.ts');
const TSX = fileURLToPath(import.meta.resolve('tsx'));

const SPEC = {
  goal: 'add a --version flag',
  scope: ['tool.py'],
  approach: 'argparse',
  acceptance: ['tool.py --version prints it'],
  outOfScope: [],
};

interface Event {
  event: string;
  params: Record<string, unknown>;
}

let root = '';
let repo = '';
let runtime = '';
let scriptPath = '';
let store: BigStore;
let big: BigService;
let detached: DetachedService;
let events: Event[];
let inlineTurns: SDKMessage[][];

function gitInit(dir: string): void {
  mkdirSync(dir, { recursive: true });
  const run = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'pipe' });
  };
  run('init', '-q', '-b', 'main');
  configureGitIdentity(dir);
  writeFileSync(join(dir, 'tool.py'), 'def main():\n    print("hi")\n');
  run('add', '-A');
  run('commit', '-qm', 'initial');
}

/** The sidecar's own SDK: only ever used for intake and the fallback build. */
function inlineSdk(): BigService['constructor'] extends never ? never : ConstructorParameters<typeof BigService>[0]['sdk'] {
  return {
    query: ({ prompt }: { prompt: string | AsyncIterable<SDKUserMessage>; options?: Options }) => {
      const frames = inlineTurns.shift();
      assert.ok(frames !== undefined, `no scripted inline turn for: ${String(prompt).slice(0, 60)}`);
      return (async function* () {
        for (const frame of frames) yield frame;
      })();
    },
  };
}

const init = (): SDKMessage =>
  ({ type: 'system', subtype: 'init', session_id: 'inline', model: 'inline-model' }) as unknown as SDKMessage;

const result = (text: string, structured?: unknown): SDKMessage =>
  ({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: text,
    structured_output: structured,
    session_id: 'inline',
    num_turns: 1,
    total_cost_usd: 0,
    usage: { input_tokens: 1, output_tokens: 1 },
  }) as unknown as SDKMessage;

function writeScript(script: FakeScript): void {
  writeFileSync(scriptPath, JSON.stringify(script));
}

function detachedEnv(overrides: Record<string, string> = {}): Record<string, string | undefined> {
  return {
    ...process.env,
    XDG_RUNTIME_DIR: runtime,
    NVIME_FAKE_SCRIPT: scriptPath,
    NVIME_RUNNER_ARGV: JSON.stringify([process.execPath, '--import', TSX, FAKE_RUNNER]),
    ...overrides,
  };
}

function makeDetached(overrides: Record<string, string> = {}): DetachedService {
  return new DetachedService({
    big,
    store,
    env: detachedEnv(overrides),
    emit: (event, params) => events.push({ event, params }),
  });
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-det-'));
  repo = join(root, 'repo');
  runtime = join(root, 'run');
  mkdirSync(runtime, { recursive: true });
  scriptPath = join(root, 'script.json');
  writeScript({});
  gitInit(repo);
  store = new BigStore(join(root, 'store'));
  events = [];
  inlineTurns = [];
  big = new BigService({
    sdk: inlineSdk(),
    store,
    claudePath: '/usr/bin/true',
    env: { PATH: process.env.PATH },
    emit: (event, params) => events.push({ event, params }),
  });
  detached = makeDetached();
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** Drafts, answers intake with a ready spec, and approves. */
async function approved(): Promise<SessionView> {
  const created = big.create(repo, 'version flag', 'medium');
  inlineTurns.push([init(), result('spec', { ready: true, message: 'here', spec: SPEC })]);
  await big.intake(1, { root: repo, id: created.id, message: 'add a --version flag' });
  return big.approve(repo, created.id);
}

function logOf(id: string): RunEvent[] {
  return readEventsAfter(store.logPathFor(repo, id), 0);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Waits for `check`, or fails the test with `what` rather than hanging forever. */
async function until(what: string, check: () => boolean, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return;
    await sleep(25);
  }
  assert.fail(`timed out waiting for ${what}`);
}

describe('a detached build', () => {
  it('runs in its own process, records every event, and ends with threads', async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' }, holdMs: 50 });

    const view = await detached.start(1, 'build', { root: repo, id: session.id });

    assert.equal(view.display, 'reviewing');
    assert.ok(view.counts.total > 0, 'the triage turn ran runner-side too, so there are threads to review');
    assert.equal(view.runner, null, 'a runner that finished clears itself off the record');

    const log = logOf(session.id);
    assert.deepEqual(
      log.map((entry) => entry.seq),
      log.map((_, index) => index + 1),
      'the log is numbered without gaps',
    );
    const names = log.map((entry) => entry.event);
    assert.ok(names.includes('big.delta'), names.join(','));
    assert.ok(names.includes('big.tool'), names.join(','));
    assert.equal(names[names.length - 1], 'big.done', 'the terminal event is written before the runner exits');
    assert.ok(
      events.some((entry) => entry.event === 'big.delta' && entry.params.id === 1),
      'the run streams into the request that started it',
    );
  });

  it('keeps building when the editor that started it lets go, and can be attached to again', async () => {
    const session = await approved();
    writeScript({
      write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' },
      holdMs: 1500,
      readyOut: join(root, 'ready'),
    });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));

    // A second editor: its own service, its own store handle, same session.
    const other = new DetachedService({
      big,
      store: new BigStore(join(root, 'store')),
      env: detachedEnv(),
      emit: (event, params) => events.push({ event, params: { ...params, viewer: 'other' } }),
    });
    const attached = await other.attach(2, { root: repo, id: session.id, after: 0 });
    await running;

    assert.ok(attached.seq > 0);
    const seenByOther = events.filter((entry) => entry.params.viewer === 'other');
    assert.ok(seenByOther.length > 0, 'the second viewer saw the run');
    assert.ok(
      seenByOther.some((entry) => entry.event === 'big.done'),
      'and followed it to the end',
    );
  });

  it('replays for a viewer that was never there, from any offset and the same way twice', async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' } });
    await detached.start(1, 'build', { root: repo, id: session.id });

    const full = logOf(session.id);
    const seen: Event[] = [];
    const viewer = new DetachedService({
      big,
      store,
      env: detachedEnv(),
      emit: (event, params) => seen.push({ event, params }),
    });

    await viewer.attach(7, { root: repo, id: session.id, after: 0 });
    const first = seen.map((entry) => entry.params.seq);
    seen.length = 0;
    await viewer.attach(7, { root: repo, id: session.id, after: 0 });
    assert.deepEqual(seen.map((entry) => entry.params.seq), first, 'the same offset renders the same thing');

    seen.length = 0;
    await viewer.attach(7, { root: repo, id: session.id, after: 2 });
    assert.deepEqual(
      seen.map((entry) => entry.params.seq),
      full.slice(2).map((entry) => entry.seq),
      'and an offset replays only what follows it',
    );
  });
});

describe('steering a running build', () => {
  it('queues a steer, delivers it to the agent, and records both states in order', async () => {
    const session = await approved();
    const steers = join(root, 'steers');
    writeScript({
      write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' },
      holdMs: 2000,
      readyOut: join(root, 'ready'),
      steersOut: steers,
    });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));
    assert.deepEqual(await detached.steer({ root: repo, id: session.id, text: 'also add a --help flag' }), {
      queued: true,
    });
    await running;

    assert.equal(readFileSync(steers, 'utf8').trim(), 'also add a --help flag', 'the agent read it');
    const states = logOf(session.id)
      .filter((entry) => entry.event === 'big.steer')
      .map((entry) => [entry.params.steerId, entry.params.state]);
    assert.deepEqual(states, [
      [1, 'queued'],
      [1, 'delivered'],
    ]);
  });

  it('refuses a steer when no build is running rather than pretending it landed', async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'x = 1\n' } });
    await detached.start(1, 'build', { root: repo, id: session.id });
    await assert.rejects(
      detached.steer({ root: repo, id: session.id, text: 'too late' }),
      /no running build to steer/,
    );
  });
});

describe('stopping a detached build', () => {
  it('stops it through the socket, and the record says stopped rather than built', async () => {
    const session = await approved();
    writeScript({ holdMs: 60_000, readyOut: join(root, 'ready') });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));
    const pid = store.require(repo, session.id).runner?.pid;
    assert.ok(pid !== undefined);

    assert.deepEqual(await detached.stop({ root: repo, id: session.id }), { stopped: true });
    await assert.rejects(running, /stopped/);

    await until('the runner to exit', () => !alive(pid));
    const terminal = logOf(session.id).pop();
    assert.equal(terminal?.event, 'big.failed');
    assert.equal(terminal?.params.code, 'cancelled');
    assert.equal(existsSync(store.lockPathFor(repo, session.id)), false, 'the claim is released');
    assert.equal(big.open(repo, session.id).runner, null, 'and the runner is off the record');
  });

  it('reports a killed runner as a build that died, still resumable, never as building', async () => {
    const session = await approved();
    writeScript({ holdMs: 60_000, readyOut: join(root, 'ready') });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));
    const pid = store.require(repo, session.id).runner?.pid;
    assert.ok(pid !== undefined);
    process.kill(pid, 'SIGKILL');

    await assert.rejects(running, /stopped without finishing/);
    await until('the runner to die', () => !alive(pid));

    const view = big.open(repo, session.id);
    assert.equal(view.display, 'building', 'the build is where it got to');
    assert.equal(view.detached, true, 'and nobody is driving it');
    assert.equal(view.runnerLive, false);
    assert.ok(view.runner !== null, 'the dead runner stays on the record — that is what makes it "died"');
    assert.equal(logOf(session.id).some((entry) => entry.event === 'big.done'), false, 'no terminal event was faked');
  });
});

describe('when the runner cannot start', () => {
  it('falls back to building in the sidecar, and says so out loud', async () => {
    const session = await approved();
    const broken = makeDetached({ NVIME_RUNNER_ARGV: JSON.stringify([join(root, 'no-such-node')]) });
    inlineTurns.push([init(), result('built it')]);
    inlineTurns.push([init(), result('triaged', { blocks: [] })]);

    const view = await broken.start(1, 'build', { root: repo, id: session.id });

    assert.equal(view.display, 'reviewing');
    const notice = events.find((entry) => entry.event === 'big.notice');
    assert.match(String(notice?.params.text), /detached build runner could not start/);
    assert.match(String(notice?.params.text), /close Neovim/);
  });

  it('runs in the sidecar with no notice at all when detached builds are switched off', async () => {
    const session = await approved();
    const inline = makeDetached({ NVIME_DETACHED: '0' });
    inlineTurns.push([init(), result('built it')]);
    inlineTurns.push([init(), result('triaged', { blocks: [] })]);

    await inline.start(1, 'build', { root: repo, id: session.id });
    assert.equal(events.some((entry) => entry.event === 'big.notice'), false);
    assert.equal(existsSync(store.logPathFor(repo, session.id)), false, 'and writes no run log');
  });

  it('refuses to start a second build over a live one', async () => {
    const session = await approved();
    writeScript({ holdMs: 60_000, readyOut: join(root, 'ready') });
    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));

    await assert.rejects(
      makeDetached().start(2, 'build', { root: repo, id: session.id }),
      /already running/,
    );
    await detached.stop({ root: repo, id: session.id });
    await assert.rejects(running);
  });
});

describe('the control socket', () => {
  it('lives outside the session store, where a unix path length still fits', async () => {
    const session = await approved();
    const path = socketPathFor({ XDG_RUNTIME_DIR: runtime }, repo, session.id);
    assert.ok(!path.startsWith(store.root), 'never in the deep store directory');
    assert.ok(Buffer.byteLength(path, 'utf8') <= 100, path);
  });
});

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (cause) {
    return (cause as NodeJS.ErrnoException).code === 'EPERM';
  }
}
