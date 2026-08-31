import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  LineSplitter,
  MAX_LINE_BYTES,
  ProtocolError,
  encodeFrame,
  parseRequest,
} from '../src/protocol.js';

describe('LineSplitter', () => {
  it('yields whole lines only', () => {
    const splitter = new LineSplitter();
    assert.deepEqual(splitter.push('{"a":1}\n{"b":2}\n'), ['{"a":1}', '{"b":2}']);
    assert.equal(splitter.pending, 0);
  });

  it('holds a partial line until its newline arrives', () => {
    const splitter = new LineSplitter();
    assert.deepEqual(splitter.push('{"a":'), []);
    assert.ok(splitter.pending > 0);
    assert.deepEqual(splitter.push('1}\n'), ['{"a":1}']);
    assert.equal(splitter.pending, 0);
  });

  it('reassembles a frame split mid-multibyte-free chunk boundaries', () => {
    const splitter = new LineSplitter();
    const frame = JSON.stringify({ id: 1, method: 'ping', params: {} });
    const out: string[] = [];
    for (const char of (frame + '\n').split('')) out.push(...splitter.push(char));
    assert.deepEqual(out, [frame]);
  });

  it('drops blank lines rather than emitting empty frames', () => {
    const splitter = new LineSplitter();
    assert.deepEqual(splitter.push('\n\n  \n{"a":1}\n'), ['{"a":1}']);
  });

  it('treats an unbounded line as a fatal desync', () => {
    const splitter = new LineSplitter();
    assert.throws(
      () => splitter.push('x'.repeat(MAX_LINE_BYTES + 1)),
      (error: unknown) => error instanceof ProtocolError && error.code === 'bad_request',
    );
    assert.equal(splitter.pending, 0, 'buffer is released after the desync');
  });
});

describe('parseRequest', () => {
  it('accepts a well-formed request and defaults params', () => {
    assert.deepEqual(parseRequest('{"id":7,"method":"ping"}'), {
      id: 7,
      method: 'ping',
      params: {},
    });
  });

  for (const [label, line] of [
    ['malformed JSON', '{'],
    ['a JSON array', '[1,2]'],
    ['a missing id', '{"method":"ping"}'],
    ['a fractional id', '{"id":1.5,"method":"ping"}'],
    ['an empty method', '{"id":1,"method":""}'],
    ['array params', '{"id":1,"method":"ping","params":[]}'],
  ] as const) {
    it(`rejects ${label}`, () => {
      assert.throws(
        () => parseRequest(line),
        (error: unknown) => error instanceof ProtocolError && error.code === 'bad_request',
      );
    });
  }
});

describe('encodeFrame', () => {
  it('emits exactly one newline-terminated line', () => {
    const line = encodeFrame({ id: 1, ok: true, result: { text: 'a\nb' } });
    assert.equal(line.endsWith('\n'), true);
    assert.equal(line.slice(0, -1).includes('\n'), false, 'embedded newlines stay escaped');
  });

  it('round-trips through the splitter', () => {
    const splitter = new LineSplitter();
    const frame = { event: 'chat.delta', params: { id: 3, text: 'hi\nthere' } };
    const [line] = splitter.push(encodeFrame(frame));
    assert.ok(line !== undefined);
    assert.deepEqual(JSON.parse(line), frame);
  });
});
