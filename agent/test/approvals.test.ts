import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { ApprovalGate } from '../src/approvals.js';

describe('ApprovalGate', () => {
  it('resolves allowed when the editor says yes', async () => {
    const gate = new ApprovalGate(5_000);
    const waiting = gate.request('a');
    assert.equal(gate.pending, 1);
    assert.equal(gate.answer('a', true), true);
    assert.deepEqual(await waiting, { allowed: true, reason: 'allowed in the editor' });
    assert.equal(gate.pending, 0);
  });

  it('resolves denied when the editor says no', async () => {
    const gate = new ApprovalGate(5_000);
    const waiting = gate.request('a');
    gate.answer('a', false);
    assert.equal((await waiting).allowed, false);
  });

  it('denies when nobody answers before the deadline', async () => {
    const gate = new ApprovalGate(20);
    const outcome = await gate.request('a');
    assert.equal(outcome.allowed, false, 'a permission prompt must never fail open');
    assert.match(outcome.reason, /no answer from the editor/);
    assert.equal(gate.pending, 0);
  });

  it('denies when the run is cancelled while the ask is parked', async () => {
    const gate = new ApprovalGate(5_000);
    const abort = new AbortController();
    const waiting = gate.request('a', abort.signal);
    abort.abort();
    assert.deepEqual(await waiting, { allowed: false, reason: 'the run was cancelled' });
  });

  it('denies immediately when the run was already cancelled', async () => {
    const gate = new ApprovalGate(5_000);
    const abort = new AbortController();
    abort.abort();
    assert.equal((await gate.request('a', abort.signal)).allowed, false);
    assert.equal(gate.pending, 0);
  });

  it('unparks a leftover ask when its run ends', async () => {
    const gate = new ApprovalGate(5_000);
    const waiting = gate.request('a');
    assert.equal(gate.deny('a', 'the edit run ended'), true);
    assert.deepEqual(await waiting, { allowed: false, reason: 'the edit run ended' });
    assert.equal(gate.deny('a', 'again'), false, 'and denying twice settles nothing new');
  });

  it('reports an answer to an id nobody is waiting on', () => {
    const gate = new ApprovalGate(5_000);
    assert.equal(gate.answer('nope', true), false);
  });

  it('denies a reused id instead of throwing into the run', async () => {
    const gate = new ApprovalGate(5_000);
    const waiting = gate.request('a');
    const duplicate = await gate.request('a');
    assert.equal(duplicate.allowed, false);
    assert.match(duplicate.reason, /already pending/);
    assert.equal(gate.pending, 1, 'the ask on screen is untouched');
    assert.equal(gate.answer('a', true), true, 'and answering it still reaches the first caller');
    assert.deepEqual(await waiting, { allowed: true, reason: 'allowed in the editor' });
  });

  it('reports whether an id is still on the editor screen', async () => {
    const gate = new ApprovalGate(5_000);
    assert.equal(gate.isPending('a'), false);
    const waiting = gate.request('a');
    assert.equal(gate.isPending('a'), true);
    gate.answer('a', false);
    await waiting;
    assert.equal(gate.isPending('a'), false);
  });

  it('refuses a nonsensical deadline instead of never timing out', () => {
    assert.throws(() => new ApprovalGate(0), /positive timeout/);
  });
});
