import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Options, SDKMessage, SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import type { BigSdk } from '../../src/big.js';
import { readJob, runJob } from '../../src/runner.js';

/**
 * A detached runner whose SDK is scripted from a JSON file. Spawned by
 * `detached.test.ts` exactly the way the sidecar spawns the real one, so the
 * process lifecycle under test — detached, stdio to files, socket, claim,
 * terminal event — is the real one and only the agent is a stand-in.
 *
 * Usage: node --import tsx fake-runner.ts <job.json>, with NVIME_FAKE_SCRIPT
 * naming the script file.
 */

export interface FakeScript {
  /** What the build turn writes, relative to the clone. */
  write?: { path: string; content: string };
  /** How long the build turn runs before answering. Steers land in this window. */
  holdMs?: number;
  /** File the build turn appends each steer it read to, one per line. */
  steersOut?: string;
  /** File the build turn touches as soon as it is running. */
  readyOut?: string;
  /** Make the build turn end in a failure result instead. */
  failWith?: string;
  triageTitle?: string;
}

function readScript(): FakeScript {
  const path = process.env.NVIME_FAKE_SCRIPT;
  if (path === undefined || path === '') throw new Error('NVIME_FAKE_SCRIPT is not set');
  return JSON.parse(readFileSync(path, 'utf8')) as FakeScript;
}

/**
 * Everything the input stream has produced, drained eagerly. The real CLI reads
 * its stdin the same way and queues what arrives mid-turn, which is why
 * `queued_turn_count` can be non-zero on a result — this mirrors that.
 */
class Inbox {
  readonly #queue: string[] = [];
  #done = false;
  #wake: ((text: string | null) => void) | null = null;

  constructor(input: AsyncIterable<SDKUserMessage>) {
    void (async () => {
      for await (const message of input) this.#push(textOf(message));
      this.#done = true;
      this.#wake?.(null);
      this.#wake = null;
    })();
  }

  get depth(): number {
    return this.#queue.length;
  }

  next(): Promise<string | null> {
    const ready = this.#queue.shift();
    if (ready !== undefined) return Promise.resolve(ready);
    if (this.#done) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.#wake = resolve;
    });
  }

  #push(text: string): void {
    const wake = this.#wake;
    if (wake !== null) {
      this.#wake = null;
      wake(text);
      return;
    }
    this.#queue.push(text);
  }
}

function textOf(message: SDKUserMessage): string {
  const content = message.message.content;
  return typeof content === 'string' ? content : JSON.stringify(content);
}

const init = (): SDKMessage =>
  ({ type: 'system', subtype: 'init', session_id: 'fake-session', model: 'fake-model' }) as unknown as SDKMessage;

const delta = (text: string): SDKMessage =>
  ({
    type: 'stream_event',
    event: { type: 'content_block_delta', delta: { type: 'text_delta', text } },
  }) as unknown as SDKMessage;

const toolUse = (name: string, input: Record<string, unknown>): SDKMessage =>
  ({
    type: 'assistant',
    message: { content: [{ type: 'tool_use', id: 't1', name, input }] },
  }) as unknown as SDKMessage;

const result = (text: string, structured: unknown, queued: number): SDKMessage =>
  ({
    type: 'result',
    subtype: 'success',
    is_error: false,
    result: text,
    structured_output: structured,
    session_id: 'fake-session',
    num_turns: 1,
    total_cost_usd: 0,
    usage: { input_tokens: 1, output_tokens: 1 },
    queued_turn_count: queued,
  }) as unknown as SDKMessage;

/** Waits `ms`, or rejects the moment the turn is aborted. */
function hold(ms: number, signal: AbortSignal | undefined): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted === true) {
      reject(new Error('aborted'));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    function onAbort(): void {
      clearTimeout(timer);
      reject(new Error('aborted'));
    }
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}

async function* buildTurn(
  input: AsyncIterable<SDKUserMessage>,
  options: Options,
  script: FakeScript,
): AsyncGenerator<SDKMessage> {
  const inbox = new Inbox(input);
  const opening = await inbox.next();
  if (opening === null) throw new Error('the build turn was given no prompt');
  yield init();
  yield delta('starting the build\n');
  if (script.readyOut !== undefined) writeFileSync(script.readyOut, 'running\n');

  const write = script.write;
  if (write !== undefined) {
    const target = join(String(options.cwd), write.path);
    yield toolUse('Write', { file_path: target, content: write.content });
    const decide = options.canUseTool;
    if (decide === undefined) throw new Error('a build turn must install a permission callback');
    const decision = await decide(
      'Write',
      { file_path: target, content: write.content },
      { signal: new AbortController().signal, toolUseID: 't1', requestId: 'r1' },
    );
    if (decision === null || decision.behavior !== 'allow') throw new Error('the write was refused');
    writeFileSync(target, write.content);
  }

  await hold(script.holdMs ?? 0, options.abortController?.signal);
  if (script.failWith !== undefined) throw new Error(script.failWith);
  yield result('built it', undefined, inbox.depth);

  for (;;) {
    const steer = await inbox.next();
    if (steer === null) return;
    if (script.steersOut !== undefined) appendFileSync(script.steersOut, `${steer}\n`);
    yield delta(`heard: ${steer}\n`);
    yield result('applied the steer', undefined, inbox.depth);
  }
}

/** The triage turn: one thread over every hunk the prompt showed. */
function* readOnlyTurn(prompt: string, script: FakeScript): Generator<SDKMessage> {
  const ids = [...prompt.matchAll(/^\[(h[0-9a-f_]+)\]/gm)].map((match) => match[1]);
  yield init();
  yield result('triaged', {
    blocks: [{ title: script.triageTitle ?? 'the change', hunkIds: ids, substantial: false, rationale: 'scripted' }],
  }, 0);
}

function scriptedSdk(script: FakeScript): BigSdk {
  return {
    query: ({ prompt, options }) => {
      const turnOptions = options ?? ({} as Options);
      if (typeof prompt === 'string') {
        return (async function* () {
          yield* readOnlyTurn(prompt, script);
        })();
      }
      return buildTurn(prompt, turnOptions, script);
    },
  };
}

async function main(): Promise<void> {
  const jobPath = process.argv[2];
  if (jobPath === undefined) throw new Error('usage: fake-runner <job.json>');
  const code = await runJob(readJob(jobPath), {
    sdk: scriptedSdk(readScript()),
    claudePath: '/usr/bin/true',
    env: process.env,
  });
  process.exit(code);
}

void main().catch((cause: unknown) => {
  process.stderr.write(`fake-runner: ${cause instanceof Error ? (cause.stack ?? cause.message) : String(cause)}\n`);
  process.exit(1);
});
