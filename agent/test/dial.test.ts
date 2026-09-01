import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { dialOptions, parseDial } from '../src/dial.js';
import { ProtocolError } from '../src/protocol.js';

describe('parseDial', () => {
  it('reads model and effort when both are given', () => {
    assert.deepEqual(parseDial({ model: 'claude-opus-5', effort: 'high' }), {
      model: 'claude-opus-5',
      effort: 'high',
    });
  });

  it('leaves both undefined when neither params key is present', () => {
    assert.deepEqual(parseDial({}), { model: undefined, effort: undefined });
  });

  it('rejects a non-string model', () => {
    assert.throws(
      () => parseDial({ model: 5 }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'bad_request' && /params\.model/.test(error.message),
    );
  });

  it('rejects an effort outside low/medium/high', () => {
    assert.throws(
      () => parseDial({ effort: 'xhigh' }),
      (error: unknown) => error instanceof ProtocolError && error.code === 'bad_request' && /params\.effort/.test(error.message),
    );
  });
});

describe('dialOptions', () => {
  it('spreads only the fields that are set', () => {
    assert.deepEqual(dialOptions({}), {});
    assert.deepEqual(dialOptions({ model: 'claude-opus-5' }), { model: 'claude-opus-5' });
    assert.deepEqual(dialOptions({ effort: 'medium' }), { effort: 'medium' });
    assert.deepEqual(dialOptions({ model: 'claude-opus-5', effort: 'medium' }), {
      model: 'claude-opus-5',
      effort: 'medium',
    });
  });
});
