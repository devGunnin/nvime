import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { ProtocolError, type OutgoingFrame } from '../src/protocol.js';
import { Dispatcher } from '../src/rpc.js';

function harness() {
  const frames: OutgoingFrame[] = [];
  return { frames, dispatcher: new Dispatcher((frame) => frames.push(frame)) };
}

const settled = () => new Promise((resolve) => setImmediate(resolve));

describe('Dispatcher', () => {
  it('answers a known method with its result', async () => {
    const h = harness();
    h.dispatcher.register('ping', async () => ({ pong: true }));
    h.dispatcher.handleLine('{"id":1,"method":"ping"}');
    await settled();
    assert.deepEqual(h.frames, [{ id: 1, ok: true, result: { pong: true } }]);
  });

  it('passes the request id to the handler, so a run can be cancelled', async () => {
    const h = harness();
    let seen = -1;
    h.dispatcher.register('chat.send', async (id) => {
      seen = id;
      return null;
    });
    h.dispatcher.handleLine('{"id":42,"method":"chat.send"}');
    await settled();
    assert.equal(seen, 42);
  });

  // F6: an unknown method was answered but never logged, so a plugin/sidecar
  // version mismatch — exactly what the log exists to diagnose — left a reply
  // in the timeline with no request above it.
  it('logs the request for a method it does not know', async () => {
    const lines: string[] = [];
    const log = {
      enabled: () => true,
      request: (method: string, id: number) => lines.push(`req ${method} #${id}`),
      reply: (method: string, id: number, ms: number, code?: string) =>
        lines.push(`rep ${method} #${id} ${code ?? 'ok'}`),
    };
    const frames: OutgoingFrame[] = [];
    const dispatcher = new Dispatcher((frame) => frames.push(frame), log as never);
    dispatcher.handleLine('{"id":9,"method":"nope"}');
    await settled();
    assert.deepEqual(lines, ['req nope #9', 'rep nope #9 unknown_method'], lines.join(' | '));
  });

  it('reports an unknown method against its own id', async () => {
    const h = harness();
    h.dispatcher.handleLine('{"id":2,"method":"nope"}');
    await settled();
    assert.equal((h.frames[0] as { error: { code: string } }).error.code, 'unknown_method');
  });

  it('translates a handler failure into its own error code', async () => {
    const h = harness();
    h.dispatcher.register('boom', async () => {
      throw new ProtocolError('not_logged_in', 'sign in', 'detail');
    });
    h.dispatcher.handleLine('{"id":3,"method":"boom"}');
    await settled();
    assert.deepEqual(h.frames[0], {
      id: 3,
      ok: false,
      error: { code: 'not_logged_in', message: 'sign in', detail: 'detail' },
    });
  });

  it('never lets an unexpected throw escape as a crash', async () => {
    const h = harness();
    h.dispatcher.register('boom', async () => {
      throw new TypeError('undefined is not a function');
    });
    h.dispatcher.handleLine('{"id":4,"method":"boom"}');
    await settled();
    assert.equal((h.frames[0] as { error: { code: string } }).error.code, 'internal');
  });

  it('reports an unattributable line as an event, since there is no id to answer', async () => {
    const h = harness();
    h.dispatcher.handleLine('{ not json');
    await settled();
    assert.equal((h.frames[0] as { event: string }).event, 'rpc.error');
  });

  it('answers a rejected frame against its own id when it named one', async () => {
    // An event settles no pending callback: the plugin's spinner would spin
    // forever and every later send would answer "a turn is already running".
    const h = harness();
    h.dispatcher.handleLine('{"id":9,"method":"ping","params":[]}');
    await settled();
    assert.deepEqual(h.frames, [
      {
        id: 9,
        ok: false,
        error: { code: 'bad_request', message: 'frame.params must be an object when present' },
      },
    ]);
  });

  it('answers a missing method against its id too', async () => {
    const h = harness();
    h.dispatcher.handleLine('{"id":10}');
    await settled();
    assert.equal((h.frames[0] as { id: number }).id, 10);
    assert.equal((h.frames[0] as { error: { code: string } }).error.code, 'bad_request');
  });

  it('falls back to an event only when the id itself is unusable', async () => {
    const h = harness();
    h.dispatcher.handleLine('{"id":"seven","method":"ping"}');
    await settled();
    assert.equal((h.frames[0] as { event: string }).event, 'rpc.error');
  });

  it('refuses to register a method twice', () => {
    const h = harness();
    h.dispatcher.register('ping', async () => null);
    assert.throws(() => h.dispatcher.register('ping', async () => null), /duplicate handler/);
  });

  it('serves a second request while the first is still running', async () => {
    const h = harness();
    let release = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    h.dispatcher.register('slow', async () => {
      await gate;
      return 'slow';
    });
    h.dispatcher.register('fast', async () => 'fast');
    h.dispatcher.handleLine('{"id":1,"method":"slow"}');
    h.dispatcher.handleLine('{"id":2,"method":"fast"}');
    await settled();
    assert.deepEqual(h.frames, [{ id: 2, ok: true, result: 'fast' }], 'the fast reply does not wait');
    release();
    await settled();
    assert.equal(h.frames.length, 2);
  });

  it('counts in-flight requests so shutdown can drain them', async () => {
    const h = harness();
    let release = () => {};
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    h.dispatcher.register('slow', async () => {
      await gate;
      return null;
    });
    assert.equal(h.dispatcher.inflight, 0);
    h.dispatcher.handleLine('{"id":1,"method":"slow"}');
    await settled();
    assert.equal(h.dispatcher.inflight, 1, 'an accepted request is counted');
    release();
    await settled();
    assert.equal(h.dispatcher.inflight, 0, 'the count is released even so');
  });
});
