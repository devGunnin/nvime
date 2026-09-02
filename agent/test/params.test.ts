import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { requireUuid } from '../src/params.js';

describe('requireUuid', () => {
  it('accepts an SDK session id in either case', () => {
    const lower = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    assert.equal(requireUuid({ sessionId: lower }, 'sessionId'), lower);
    assert.equal(requireUuid({ sessionId: lower.toUpperCase() }, 'sessionId'), lower.toUpperCase());
  });

  it('rejects anything that could name a path instead of a session', () => {
    for (const bad of ['../../etc/passwd', 'sess-1', '', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/x']) {
      assert.throws(
        () => requireUuid({ sessionId: bad }, 'sessionId'),
        /must be a session id \(UUID\)|must be a non-empty string/,
        `accepted ${JSON.stringify(bad)}`,
      );
    }
  });

  it('rejects a non-string before it can be pattern-matched', () => {
    assert.throws(() => requireUuid({ sessionId: 7 }, 'sessionId'), /non-empty string/);
  });
});
