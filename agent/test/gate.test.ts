import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  clears,
  DEFAULT_DIFFICULTY,
  gateArmed,
  isDifficulty,
  parseGradeOutput,
  pendingFollowup,
  thresholdFor,
  type GateRound,
} from '../src/gate.js';

function grade(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { threadId: 'b1', grade: 80, verdict: 'got it', hint: '', followup: '', ...overrides };
}

describe('difficulty', () => {
  it('carries the thresholds the design fixed', () => {
    assert.equal(thresholdFor('vibe'), null);
    assert.equal(thresholdFor('easy'), 40);
    assert.equal(thresholdFor('medium'), 70);
    assert.equal(thresholdFor('extreme'), 90);
    assert.equal(DEFAULT_DIFFICULTY, 'medium');
  });

  it('treats `vibe` as no gate at all, not a threshold of zero', () => {
    assert.equal(gateArmed('vibe'), false);
    for (const level of ['easy', 'medium', 'extreme'] as const) assert.equal(gateArmed(level), true);
  });

  it('rejects anything that is not one of the four', () => {
    assert.equal(isDifficulty('medium'), true);
    assert.equal(isDifficulty('MEDIUM'), false);
    assert.equal(isDifficulty(''), false);
    assert.equal(isDifficulty(undefined), false);
    assert.equal(isDifficulty(70), false);
  });
});

describe('parseGradeOutput', () => {
  it('reads a well-formed round', () => {
    const parsed = parseGradeOutput({
      grades: [grade(), grade({ threadId: 'b2', grade: 20, verdict: 'vague', hint: 'what fails?', followup: 'when?' })],
    });
    assert.ok(parsed !== null);
    assert.equal(parsed.size, 2);
    assert.deepEqual(parsed.get('b1'), { grade: 80, verdict: 'got it', hint: '', followup: '' });
    assert.equal(parsed.get('b2')?.followup, 'when?');
  });

  it('is null when the payload is not a grade list, so the caller can fall back', () => {
    assert.equal(parseGradeOutput(null), null);
    assert.equal(parseGradeOutput('87/70'), null);
    assert.equal(parseGradeOutput({}), null);
    assert.equal(parseGradeOutput({ grades: 'lots' }), null);
  });

  it('DROPS a grade that is not a usable score rather than coercing it', () => {
    // Each of these would otherwise become a number: a thread must stay open
    // on a garbage grade, and a coerced 0 or 100 is not what the grader said.
    for (const bad of [undefined, null, 'A+', NaN, Infinity, -1, 101, {}]) {
      const parsed = parseGradeOutput({ grades: [grade({ grade: bad })] });
      assert.deepEqual(parsed, new Map(), `grade ${String(bad)} must not survive`);
    }
  });

  it('drops an entry with no thread to attach it to', () => {
    assert.deepEqual(parseGradeOutput({ grades: [grade({ threadId: '' }), grade({ threadId: 7 })] }), new Map());
  });

  it('rounds a fractional score and keeps the bounds', () => {
    const parsed = parseGradeOutput({ grades: [grade({ grade: 69.6 })] });
    assert.equal(parsed?.get('b1')?.grade, 70);
  });

  it('keeps the first verdict when the grader answered twice for one thread', () => {
    const parsed = parseGradeOutput({ grades: [grade({ grade: 30 }), grade({ grade: 95 })] });
    assert.equal(parsed?.get('b1')?.grade, 30, 'a grader that contradicts itself is not trusted upward');
  });

  it('tolerates missing prose without inventing any', () => {
    const parsed = parseGradeOutput({ grades: [{ threadId: 'b1', grade: 50 }] });
    assert.deepEqual(parsed?.get('b1'), { grade: 50, verdict: '', hint: '', followup: '' });
  });
});

describe('the pass mark', () => {
  it('passes only at or above the threshold', () => {
    const at = { grade: 70, verdict: '', hint: '', followup: '' };
    assert.equal(clears(at, 70), true);
    assert.equal(clears({ ...at, grade: 69 }, 70), false);
    assert.equal(clears({ ...at, grade: 100 }, 90), true);
  });
});

describe('reading a thread history', () => {
  const graded = (score: number, followup = ''): GateRound => ({
    at: 1,
    answer: 'a',
    result: { grade: score, verdict: '', hint: '', followup },
  });
  const ungraded: GateRound = { at: 2, answer: 'a', result: null, ungraded: 'the turn failed' };

  it('names the follow-up the next answer must address', () => {
    assert.equal(pendingFollowup([graded(30, 'and what does cap protect?')]), 'and what does cap protect?');
    assert.equal(pendingFollowup([graded(90)]), null);
    assert.equal(pendingFollowup([]), null);
  });

  it('has no follow-up after a round nobody graded', () => {
    assert.equal(pendingFollowup([graded(30, 'why?'), ungraded]), null, 'an ungraded round asks nothing');
  });

});
