import assert from 'node:assert/strict';
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { isTerminal, lastSeqOf, MAX_EVENT_BYTES, readLogAfter, RunLog, type RunEvent } from '../src/runlog.js';

let root = '';
let path = '';

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-runlog-'));
  path = join(root, 'events.ndjson');
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function eventsIn(after = 0, maxBytes?: number): RunEvent[] {
  return maxBytes === undefined ? readLogAfter(path, after).events : readLogAfter(path, after, maxBytes).events;
}

describe('RunLog', () => {
  it('numbers events from one and reads them back in order', () => {
    const log = new RunLog(path);
    log.append('big.delta', { text: 'one' });
    log.append('big.tool', { tool: 'Write', summary: 'wrote tool.py' });
    log.close();

    const events = eventsIn();
    assert.deepEqual(
      events.map((event) => [event.seq, event.event]),
      [
        [1, 'big.delta'],
        [2, 'big.tool'],
      ],
    );
    assert.equal(events[0]?.params.text, 'one');
  });

  it('replays from an offset, and replaying twice renders the same thing', () => {
    const log = new RunLog(path);
    for (const text of ['a', 'b', 'c']) log.append('big.delta', { text });
    log.close();

    const tail = eventsIn(1);
    assert.deepEqual(tail.map((event) => event.params.text), ['b', 'c']);
    assert.deepEqual(eventsIn(1), tail, 'an attach at the same offset is idempotent');
    assert.deepEqual(eventsIn(3), [], 'nothing follows the last event');
  });

  it('continues the sequence when a second run appends to the same session log', () => {
    const first = new RunLog(path);
    first.append('big.delta', { text: 'build' });
    first.close();

    const second = new RunLog(path);
    assert.equal(second.seq, 1, 'the second run picks up where the first left off');
    const event = second.append('big.delta', { text: 'revise' });
    second.close();
    assert.equal(event.seq, 2);
    assert.equal(lastSeqOf(path), 2);
  });

  it('skips a line a killed runner tore in half rather than losing the whole log', () => {
    const log = new RunLog(path);
    log.append('big.delta', { text: 'before' });
    log.close();
    appendFileSync(path, '{"seq":2,"at":1,"event":"big.de');

    const events = eventsIn();
    assert.equal(events.length, 1);
    assert.equal(events[0]?.params.text, 'before');
  });

  it('never lets an append land on the line a killed runner tore in half', () => {
    const first = new RunLog(path);
    first.append('big.delta', { text: 'before' });
    first.close();
    // A runner SIGKILLed part-way through writing its terminal event.
    appendFileSync(path, '{"seq":2,"at":1,"event":"big.do');

    const second = new RunLog(path);
    const done = second.append('big.done', { state: 'reviewing' });
    second.close();

    const events = eventsIn();
    assert.ok(
      events.some((event) => event.seq === done.seq && event.event === 'big.done'),
      'a build that finished must not read as one that died because of the torn line before it',
    );
    assert.equal(lastSeqOf(path), done.seq);
  });

  it('truncates one enormous delta instead of writing a line every replay pays for', () => {
    const log = new RunLog(path);
    log.append('big.delta', { text: 'x'.repeat(MAX_EVENT_BYTES * 2) });
    log.close();

    const line = readFileSync(path, 'utf8').trim();
    assert.ok(Buffer.byteLength(line, 'utf8') <= MAX_EVENT_BYTES, 'the line is bounded');
    const event = eventsIn()[0];
    assert.equal(event?.params.truncated, true, 'and says it was cut');
  });

  it('bounds whichever field is enormous, not only the delta', () => {
    const log = new RunLog(path);
    // Neither of these is `text`: a Grep pattern and an SDK error detail are
    // just as unbounded, and the invariant is the line's size, not one field's.
    const tool = log.append('big.tool', { tool: 'Grep', summary: 'y'.repeat(MAX_EVENT_BYTES * 4) });
    log.append('big.failed', { code: 'agent_error', message: 'nope', detail: 'z'.repeat(MAX_EVENT_BYTES * 4) });
    log.close();

    for (const line of readFileSync(path, 'utf8').trim().split('\n')) {
      assert.ok(Buffer.byteLength(line, 'utf8') <= MAX_EVENT_BYTES, `a line of ${Buffer.byteLength(line, 'utf8')} bytes`);
    }
    assert.equal(tool.params.truncated, true, 'and what it returns is what it wrote');
    assert.equal(eventsIn().length, 2, 'both lines still parse');
  });

  it('replays a bounded tail of a long log and says how much it left behind', () => {
    const log = new RunLog(path);
    for (let index = 0; index < 400; index += 1) log.append('big.delta', { text: 'x'.repeat(2000) });
    log.append('big.done', { state: 'reviewing' });
    log.close();

    const slice = readLogAfter(path, 0, 64 * 1024);
    assert.ok(slice.events.length > 0 && slice.events.length < 401, `${slice.events.length} events`);
    assert.equal(slice.events[slice.events.length - 1]?.seq, 401, 'the window always reaches the newest event');
    assert.equal(slice.elided, (slice.events[0]?.seq ?? 0) - 1, 'and counts what it could not carry');
    assert.equal(lastSeqOf(path), 401, 'the last seq is read from the tail, not the whole file');
  });

  it('reports a log it cannot read as an error, never as an empty one', () => {
    // A read that fails answering 0 is what makes a fresh RunLog restart at 1
    // over a log that already holds 1..N, and every cursor after that lies.
    mkdirSync(path);
    assert.throws(() => readLogAfter(path, 0), /build log/);
    assert.throws(() => lastSeqOf(path), /build log/);
    assert.throws(() => new RunLog(path));
  });

  it('refuses to append after it is closed rather than dropping the event', () => {
    const log = new RunLog(path);
    log.close();
    assert.throws(() => log.append('big.delta', { text: 'lost' }), /closed/);
  });

  it('reads an absent log as empty — a session that has never been built', () => {
    assert.deepEqual(readLogAfter(join(root, 'nothing.ndjson'), 0), { events: [], elided: 0 });
    assert.equal(lastSeqOf(join(root, 'nothing.ndjson')), 0);
  });

  it('names the two events that end a run', () => {
    const log = new RunLog(path);
    assert.equal(isTerminal(log.append('big.delta', {})), false);
    assert.equal(isTerminal(log.append('big.done', {})), true);
    assert.equal(isTerminal(log.append('big.failed', {})), true);
    log.close();
  });

  it('ignores a line that parses but is not an event', () => {
    writeFileSync(path, `${JSON.stringify({ seq: 0, event: '', params: null })}\n`);
    assert.deepEqual(eventsIn(), []);
  });
});
