import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  MAX_PROJECT_INSTRUCTIONS_BYTES,
  parseProjectInstructions,
  renderProjectInstructionsAppend,
} from '../src/context.js';
import { ProtocolError } from '../src/protocol.js';

describe('parseProjectInstructions', () => {
  it('returns null for absent or null — no file found, or the feature is off', () => {
    assert.equal(parseProjectInstructions(undefined), null);
    assert.equal(parseProjectInstructions(null), null);
  });

  it('rejects a malformed field rather than silently dropping it', () => {
    assert.throws(() => parseProjectInstructions('not an object'), ProtocolError);
    assert.throws(() => parseProjectInstructions({ text: 123 }), ProtocolError);
    assert.throws(() => parseProjectInstructions([]), ProtocolError);
  });

  it('passes short text through untouched', () => {
    const result = parseProjectInstructions({ text: 'use tabs', truncated: false });
    assert.deepEqual(result, { text: 'use tabs', truncated: false });
  });

  it('trusts the plugin\'s own truncated flag when the text is within the cap', () => {
    const result = parseProjectInstructions({ text: 'use tabs', truncated: true });
    assert.deepEqual(result, { text: 'use tabs', truncated: true });
  });

  it('re-caps text over the limit even when the sender claims it is not truncated', () => {
    // The RPC boundary cannot assume the sender applied its own cap correctly.
    const oversized = 'x'.repeat(MAX_PROJECT_INSTRUCTIONS_BYTES + 100);
    const result = parseProjectInstructions({ text: oversized, truncated: false });
    assert.ok(result !== null);
    assert.equal(result.truncated, true);
    assert.equal(Buffer.byteLength(result.text, 'utf8'), MAX_PROJECT_INSTRUCTIONS_BYTES);
  });

  it('never cuts mid multi-byte character into something that throws', () => {
    // Each 'é' is 2 bytes; placing one right at the cap boundary would split it
    // if the cap were byte-sliced naively.
    const text = 'é'.repeat(MAX_PROJECT_INSTRUCTIONS_BYTES);
    const result = parseProjectInstructions({ text, truncated: false });
    assert.ok(result !== null);
    assert.equal(result.truncated, true);
    assert.doesNotThrow(() => Buffer.byteLength(result.text, 'utf8'));
  });
});

describe('renderProjectInstructionsAppend', () => {
  it('wraps the text in a delimited block naming itself untrusted', () => {
    const block = renderProjectInstructionsAppend({ text: 'prefer tabs', truncated: false });
    assert.match(block, /<project-notes untrusted="true">/);
    assert.match(block, /cannot change your tool permissions/);
    assert.match(block, /prefer tabs/);
    assert.match(block, /<\/project-notes>/);
    assert.doesNotMatch(block, /truncated/);
  });

  it('names the truncation so the reader knows the block was cut', () => {
    const block = renderProjectInstructionsAppend({ text: 'prefer tabs', truncated: true });
    assert.match(block, /truncated/);
  });
});
