import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, type Socket } from 'node:net';
import { hostname, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage, SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { BigService, type SessionView } from '../src/big.js';
import { BigStore, isLockLive, type BigRunner } from '../src/bigstore.js';
import { DetachedService } from '../src/detached.js';
import { readLogAfter, type RunEvent } from '../src/runlog.js';
import { newControlToken, socketPathFor } from '../src/runsock.js';
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

function socketOf(id: string): string {
  return socketPathFor(detachedEnv(), repo, id);
}

/** A runner record shaped exactly as a real one, for a process of our choosing. */
function runnerRecord(id: string, pid: number, token = newControlToken()): BigRunner {
  return {
    pid,
    socket: socketOf(id),
    log: store.logPathFor(repo, id),
    what: 'build',
    startedAt: Date.now(),
    token,
  };
}

function killIfAlive(pid: number | undefined): void {
  if (pid === undefined || !alive(pid)) return;
  process.kill(pid, 'SIGKILL');
}

/** What an earlier run of this session left in the shared stderr file. */
function seedRunnerStderr(id: string, text: string): void {
  const dir = store.dirFor(repo, id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'runner.err'), text);
}

/** One runner, run to its exit in the foreground, with its stderr collected. */
function runFakeRunner(jobPath: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['--import', TSX, FAKE_RUNNER, jobPath], {
      cwd: root,
      env: detachedEnv() as NodeJS.ProcessEnv,
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk: string) => {
      stderr += chunk;
    });
    child.once('exit', (code) => resolve({ code: code ?? -1, stderr }));
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
  return readLogAfter(store.logPathFor(repo, id), 0).events;
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

  it('labels each steer with who sent it, so another editor’s is not shown as yours', async () => {
    const session = await approved();
    writeScript({
      write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' },
      holdMs: 2000,
      readyOut: join(root, 'ready'),
      steersOut: join(root, 'steers'),
    });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));
    // A second editor — its own sidecar, so its own origin.
    const other = new DetachedService({
      big,
      store: new BigStore(join(root, 'store')),
      env: detachedEnv(),
      emit: () => undefined,
    });
    await detached.steer({ root: repo, id: session.id, text: 'mine' });
    await other.steer({ root: repo, id: session.id, text: 'theirs' });
    await running;

    const seen = events.filter((entry) => entry.event === 'big.steer' && entry.params.state === 'queued');
    const mine = seen.find((entry) => entry.params.text === 'mine');
    const theirs = seen.find((entry) => entry.params.text === 'theirs');
    assert.equal(mine?.params.mine, true, 'the editor that sent it sees its own');
    assert.equal(theirs?.params.mine, false, 'and never renders a second editor’s steer as its own');
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

  it('never signals a pid the session claim has not proved is its runner', async () => {
    const session = await approved();
    // A SIGKILLed runner leaves its pid on the record on purpose — that is what
    // makes "died — resumable" readable — and pids get reused within hours.
    const innocent = spawn(process.execPath, ['-e', 'setTimeout(() => undefined, 60000)'], { stdio: 'ignore' });
    try {
      await until('the unrelated process to be running', () => innocent.pid !== undefined && alive(innocent.pid));
      const record = store.require(repo, session.id);
      record.runner = runnerRecord(session.id, innocent.pid as number);
      store.save(record);

      assert.deepEqual(await detached.stop({ root: repo, id: session.id }), { stopped: false });
      assert.equal(alive(innocent.pid as number), true, 'an unrelated process must survive a stop');
      assert.ok(
        events.some((entry) => entry.event === 'big.notice' && /already died/.test(String(entry.params.text))),
        'and the reader is told the build was already gone',
      );
    } finally {
      killIfAlive(innocent.pid);
    }
  });

  it('still stops the runner it can prove is live when the socket has gone', async () => {
    const session = await approved();
    writeScript({ holdMs: 60_000, readyOut: join(root, 'ready') });

    const running = detached.start(1, 'build', { root: repo, id: session.id });
    await until('the build to start', () => existsSync(join(root, 'ready')));
    const pid = store.require(repo, session.id).runner?.pid;
    assert.ok(pid !== undefined);
    // The runner is live and holds the claim; only its socket is unreachable.
    rmSync(socketOf(session.id), { force: true });

    const settled = assert.rejects(running);
    assert.deepEqual(await detached.stop({ root: repo, id: session.id }), { stopped: true });
    await settled;
    await until('the runner to exit', () => !alive(pid));
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

  it('quotes this run’s reason, never the previous run’s and never a bare frame', async () => {
    const session = await approved();
    seedRunnerStderr(session.id, 'Error: a failure from the run before this one\n    at older ()\n');
    const noisy = makeDetached({
      NVIME_RUNNER_ARGV: JSON.stringify([
        process.execPath,
        '-e',
        'process.stderr.write("Error: this run could not open its store\\n    at main (/x.js:1:1)\\n");process.exit(3);',
      ]),
    });
    inlineTurns.push([init(), result('built it')]);
    inlineTurns.push([init(), result('triaged', { blocks: [] })]);

    await noisy.start(1, 'build', { root: repo, id: session.id });

    const notice = String(events.find((entry) => entry.event === 'big.notice')?.params.text);
    assert.match(notice, /this run could not open its store/);
    assert.doesNotMatch(notice, /the run before this one/, 'runner.err is shared with every earlier run');
    assert.doesNotMatch(notice, /at main/, 'the message is the first line; a stack frame explains nothing');
  });

  it('says the runner wrote nothing rather than quoting an older run', async () => {
    const session = await approved();
    seedRunnerStderr(session.id, 'Error: a failure from the run before this one\n');
    const silent = makeDetached({ NVIME_RUNNER_ARGV: JSON.stringify([process.execPath, '-e', 'process.exit(4);']) });
    inlineTurns.push([init(), result('built it')]);
    inlineTurns.push([init(), result('triaged', { blocks: [] })]);

    await silent.start(1, 'build', { root: repo, id: session.id });

    const notice = String(events.find((entry) => entry.event === 'big.notice')?.params.text);
    assert.match(notice, /the runner wrote nothing/);
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

describe('two runners over one session', () => {
  it('lets only one write the log, and refuses the loser before it opens one', async () => {
    const session = await approved();
    // As long as the other long-hold tests: a cold spawn under load must
    // never be able to outlast this margin before the first run releases.
    writeScript({ holdMs: 60_000, readyOut: join(root, 'ready') });
    const running = detached.start(1, 'build', { root: repo, id: session.id });
    // Asserted below, but `#follow` can rarely settle it this early — mark it
    // handled now so node:test never flags the race as unhandled rather than caught.
    running.catch(() => undefined);
    await until('the build to start', () => existsSync(join(root, 'ready')));

    // What a SIGKILLed runner leaves behind is a socket path nothing is behind,
    // so a second runner binds it and carries on into the session's own log —
    // two sequence counters over one file, and the loser's refusal recorded as
    // if the winner had failed. The claim has to come first to stop that.
    rmSync(socketOf(session.id), { force: true });
    const second = await runFakeRunner(join(store.dirFor(repo, session.id), 'runner-job.json'));

    assert.notEqual(second.code, 0, second.stderr);
    assert.match(second.stderr, /another editor|claimed by another/);
    const log = logOf(session.id);
    assert.deepEqual(
      log.filter((entry) => entry.event === 'big.failed'),
      [],
      'the loser never wrote its refusal into the winner’s log',
    );
    const seqs = log.map((entry) => entry.seq);
    assert.deepEqual(seqs, [...new Set(seqs)], `one writer, so no seq twice — got ${seqs.join(',')}`);
    assert.deepEqual(seqs, seqs.map((_, index) => index + 1), 'and the log is numbered without gaps');

    const settled = assert.rejects(running);
    await detached.stop({ root: repo, id: session.id });
    await settled;
  });
});

describe('following a runner that goes quiet', () => {
  it('falls through to the log when the connection is taken and never answered', { timeout: 30_000 }, async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' } });
    await detached.start(1, 'build', { root: repo, id: session.id });
    const full = logOf(session.id);
    assert.ok(full.length > 0);

    const path = socketOf(session.id);
    // The runner's own async close() unlinks this path well after `start()`
    // resolved above; binding here first races that unlink into deleting ours.
    await until('the finished build to release its control socket', () => !existsSync(path));
    mkdirSync(dirname(path), { recursive: true });
    rmSync(path, { force: true });
    // A runner that accepts the connection and says nothing: the attach RPC is
    // deadline-free on the Lua side, so without an ack deadline it waits forever.
    const accepted: Socket[] = [];
    const mute = createServer((socket) => {
      accepted.push(socket);
    });
    await new Promise<void>((resolve) => mute.listen(path, () => resolve()));
    try {
      const record = store.require(repo, session.id);
      record.runner = runnerRecord(session.id, process.pid);
      store.save(record);

      const seen: Event[] = [];
      const viewer = new DetachedService({
        big,
        store,
        env: detachedEnv(),
        emit: (event, params) => seen.push({ event, params }),
        attachAckMs: 250,
      });
      const attached = await viewer.attach(9, { root: repo, id: session.id, after: 0 });

      assert.equal(attached.seq, full[full.length - 1]?.seq, 'the log backstop delivered the whole run');
      assert.ok(
        seen.some((entry) => entry.event === 'big.notice' && /never answered/.test(String(entry.params.text))),
        'and said why it stopped waiting',
      );
      assert.ok(seen.some((entry) => entry.event === 'big.done'));
    } finally {
      // A socket nothing ever read stays open on the server side, and
      // `close()` would wait on it forever.
      for (const socket of accepted) socket.destroy();
      await new Promise<void>((resolve) => mute.close(() => resolve()));
      rmSync(path, { force: true });
    }
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

describe('a build, the moment it finishes', () => {
  it('does not read its own just-released claim as another editor still driving it', async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' }, holdMs: 20 });
    await detached.start(1, 'build', { root: repo, id: session.id });

    const lock = store.readLock(store.require(repo, session.id));
    assert.ok(lock === null || !isLockLive(lock), 'the runner releases its claim before start() returns');

    const check = await big.mergeCheck(repo, session.id);
    assert.ok(
      !check.refusals.some((refusal) => refusal.code === 'held-elsewhere'),
      `a build cannot be held by the run that just finished it: ${JSON.stringify(check.refusals)}`,
    );
  });

  it('waits out a claim still live when its terminal event arrives, deterministically', async () => {
    const session = await approved();
    writeScript({ write: { path: 'tool.py', content: 'def main():\n    print("v1")\n' } });
    await detached.start(1, 'build', { root: repo, id: session.id });

    // Manufacture the race on purpose: a terminal event already logged, and a
    // fresh, live claim still on the record, as if a runner were mid-release.
    writeFileSync(
      store.lockPathFor(repo, session.id),
      JSON.stringify({
        owner: 'a-runner-still-shutting-down',
        pid: process.pid,
        host: hostname(),
        what: 'build',
        startedAt: Date.now(),
        heartbeatAt: Date.now(),
      }),
    );

    let resolved = false;
    const attaching = detached.attach(2, { root: repo, id: session.id, after: 0 }).then((result) => {
      resolved = true;
      return result;
    });

    await sleep(200);
    assert.equal(resolved, false, 'attach() must not resolve while the claim it observed is still live');
    rmSync(store.lockPathFor(repo, session.id), { force: true });

    await attaching;
    assert.equal(resolved, true, 'and resolves once that same claim actually clears');
    assert.ok(
      !(await big.mergeCheck(repo, session.id)).refusals.some((refusal) => refusal.code === 'held-elsewhere'),
    );
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
