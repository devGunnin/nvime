import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { Options, SDKMessage, SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { BigService, STEER_CLOSED, type SessionView } from '../src/big.js';
import { BigStore } from '../src/bigstore.js';
import { SteerQueue, type SteerState } from '../src/steer.js';
import { configureGitIdentity } from './fixtures/git-identity.js';

/**
 * How a steered build turn ends, against the two shapes the shipped CLI really
 * produces for a message handed over mid-turn:
 *
 *   * FOLDED  — the agent reads it inside the turn already running, so there is
 *     exactly ONE result and no second turn will ever come.
 *   * QUEUED  — it runs as its own turn, so a SECOND result follows about a
 *     second later.
 *
 * Both results report `queued_turn_count: 0`, measured against claude 2.1.252,
 * so the two are indistinguishable at the first result. Getting this wrong in
 * either direction is fatal: end the stream too early and the steer's turn is
 * dropped, refuse to end it and the runner hangs with the build finished.
 */

const SETTLE_MS = 120;

const SPEC = {
  goal: 'add a --version flag',
  scope: ['tool.py'],
  approach: 'argparse',
  acceptance: ['tool.py --version prints it'],
  outOfScope: [],
};

const init = (): SDKMessage =>
  ({ type: 'system', subtype: 'init', session_id: 'sess', model: 'test-model' }) as unknown as SDKMessage;

/** Every result the CLI sends carries `queued_turn_count: 0`, even mid-backlog. */
const result = (text: string, structured?: unknown): SDKMessage =>
  ({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: text,
    structured_output: structured,
    session_id: 'sess',
    num_turns: 1,
    total_cost_usd: 0,
    usage: { input_tokens: 1, output_tokens: 1 },
    queued_turn_count: 0,
  }) as unknown as SDKMessage;

let root = '';
let repo = '';
let store: BigStore;
let queue: SteerQueue;
let states: Array<[number, SteerState]>;
/** Every message the build turn actually read, in order. */
let read: string[];
/** Resolves once the build turn has read its opening prompt. */
let started: Promise<void>;

/**
 * A build turn that reads its input stream eagerly, exactly as the CLI reads
 * its stdin, and then answers `shape` turns.
 */
function buildTurn(shape: 'folded' | 'queued', input: AsyncIterable<SDKUserMessage>, wake: () => void) {
  return (async function* (): AsyncGenerator<SDKMessage> {
    const iterator = input[Symbol.asyncIterator]();
    const first = await iterator.next();
    assert.equal(first.done, false);
    read.push(textOf(first.value));
    yield init();
    wake();
    if (shape === 'folded') {
      // The agent absorbs whatever arrives into the turn already running: one
      // result, and the SDK is never asked for another message.
      await new Promise((resolve) => setTimeout(resolve, SETTLE_MS / 2));
      const pulled = iterator.next();
      yield result('built it, steer included');
      const extra = await pulled;
      if (extra.done !== true) read.push(textOf(extra.value));
      return;
    }
    const pulled = iterator.next();
    yield result('built it');
    const extra = await pulled;
    if (extra.done === true) return;
    read.push(textOf(extra.value));
    yield result('and applied the steer');
    const after = await iterator.next();
    assert.equal(after.done, true, 'the stream closes after the last turn');
  })();
}

function textOf(message: SDKUserMessage): string {
  const content = message.message.content;
  return typeof content === 'string' ? content : JSON.stringify(content);
}

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

/** A service whose build turn takes `shape`, and whose other turns are canned. */
function serviceFor(shape: 'folded' | 'queued'): BigService {
  let wake = (): void => undefined;
  started = new Promise<void>((resolve) => {
    wake = resolve;
  });
  const canned: SDKMessage[][] = [];
  const service = new BigService({
    sdk: {
      query: ({ prompt, options }: { prompt: string | AsyncIterable<SDKUserMessage>; options?: Options }) => {
        if (typeof prompt !== 'string') {
          // The build writes something, so the capture has a diff to triage.
          writeFileSync(join(String(options?.cwd), 'tool.py'), 'def main():\n    print("v1")\n');
          return buildTurn(shape, prompt, wake);
        }
        const frames = canned.shift();
        assert.ok(frames !== undefined, `no canned turn for: ${prompt.slice(0, 50)}`);
        return (async function* () {
          for (const frame of frames) yield frame;
        })();
      },
    },
    store,
    claudePath: '/usr/bin/true',
    env: { PATH: process.env.PATH },
    emit: () => undefined,
    steering: queue,
    steerSettleMs: SETTLE_MS,
  });
  // Intake, then triage after the build.
  canned.push([init(), result('spec', { ready: true, message: 'here', spec: SPEC })]);
  canned.push([init(), result('triaged', { blocks: [] })]);
  return service;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-steer-'));
  repo = join(root, 'repo');
  gitInit(repo);
  store = new BigStore(join(root, 'store'));
  states = [];
  read = [];
  queue = new SteerQueue((message, state) => states.push([message.id, state]));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

async function runBuild(shape: 'folded' | 'queued'): Promise<SessionView> {
  const service = serviceFor(shape);
  const created = service.create(repo, 'version flag', 'vibe');
  await service.intake(1, { root: repo, id: created.id, message: 'add a --version flag' });
  await service.approve(repo, created.id);
  const building = service.build(2, { root: repo, id: created.id });
  await started;
  queue.push('also add a --help flag');
  return building;
}

describe('a steered build turn', () => {
  it('finishes when the agent folded the steer into the turn already running', async () => {
    const view = await runBuild('folded');
    assert.equal(view.state, 'reviewing', 'a folded steer must not leave the build waiting for a turn that never comes');
    assert.deepEqual(read.slice(1), ['also add a --help flag'], 'and the steer still reached the agent');
    assert.deepEqual(states, [
      [1, 'queued'],
      [1, 'delivered'],
    ]);
  });

  it('waits for the steer to run as its own turn rather than cutting the stream', async () => {
    const view = await runBuild('queued');
    assert.equal(view.state, 'reviewing');
    assert.deepEqual(
      read.slice(1),
      ['also add a --help flag'],
      'the second turn got its message; ending the stream at the first result would have dropped it',
    );
  });

  it('refuses a steer once the build agent has stopped taking input', async () => {
    await runBuild('folded');
    assert.deepEqual(queue.push('too late'), {
      queued: false,
      reason: STEER_CLOSED,
    });
  });
});
