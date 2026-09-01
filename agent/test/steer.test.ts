import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import type { SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { MAX_STEER_CHARS, SteerQueue, steeredPrompt, type SteerState } from '../src/steer.js';

function recorder(): { states: Array<[number, SteerState]>; queue: SteerQueue } {
  const states: Array<[number, SteerState]> = [];
  const queue = new SteerQueue((message, state) => states.push([message.id, state]));
  return { states, queue };
}

function textOf(message: SDKUserMessage): string {
  const content = message.message.content;
  return typeof content === 'string' ? content : JSON.stringify(content);
}

describe('SteerQueue', () => {
  it('records queued when it is accepted and delivered when the agent asks for it', async () => {
    const { states, queue } = recorder();
    assert.deepEqual(queue.push('use the retry helper'), { queued: true, id: 1 });
    assert.deepEqual(states, [[1, 'queued']]);

    const message = await queue.next();
    assert.ok(message !== null);
    queue.markDelivered(message);
    assert.deepEqual(states, [
      [1, 'queued'],
      [1, 'delivered'],
    ]);
  });

  it('hands a steer straight to a turn that is already waiting for input', async () => {
    const { queue } = recorder();
    const waiting = queue.next();
    queue.push('and a --help flag');
    assert.equal((await waiting)?.text, 'and a --help flag');
  });

  it('refuses a steer once the build has finished, rather than swallowing it', () => {
    const { queue } = recorder();
    queue.close('the build has finished');
    assert.deepEqual(queue.push('too late'), { queued: false, reason: 'the build has finished' });
  });

  it('validates the text at the boundary', () => {
    const { queue } = recorder();
    assert.equal(queue.push('   ').queued, false);
    assert.equal(queue.push('x'.repeat(MAX_STEER_CHARS + 1)).queued, false);
    assert.equal(queue.push('x'.repeat(MAX_STEER_CHARS)).queued, true);
  });

  it('still hands over what it already accepted when it is closed', async () => {
    const { queue } = recorder();
    queue.push('one');
    queue.close('the build has finished');
    assert.equal((await queue.next())?.text, 'one', 'an accepted steer is never dropped');
    assert.equal(await queue.next(), null);
  });

  it('owes a turn from the moment a steer is delivered until one result answers it', async () => {
    const { queue } = recorder();
    assert.equal(queue.awaitingTurn, false);
    queue.push('one');
    const message = await queue.next();
    assert.ok(message !== null);
    queue.markDelivered(message);
    assert.equal(queue.awaitingTurn, true, 'the delivered steer has not been answered yet');
    queue.noteTurn();
    assert.equal(queue.awaitingTurn, false);
  });
});

describe('steeredPrompt', () => {
  it('yields the opening, then each steer, and ends when the queue closes', async () => {
    const { queue } = recorder();
    const stream = steeredPrompt('build the thing', queue);

    assert.equal(textOf((await stream.next()).value as SDKUserMessage), 'build the thing');
    queue.push('also add --help');
    assert.equal(textOf((await stream.next()).value as SDKUserMessage), 'also add --help');
    queue.close('done');
    assert.equal((await stream.next()).done, true);
  });

  it('marks a steer delivered only when the SDK asks for it, never when it is queued', async () => {
    const { states, queue } = recorder();
    const stream = steeredPrompt('build the thing', queue);
    await stream.next();
    queue.push('later');
    assert.deepEqual(states, [[1, 'queued']], 'nothing is delivered while the turn is busy');
    await stream.next();
    assert.deepEqual(states, [
      [1, 'queued'],
      [1, 'delivered'],
    ]);
  });
});
