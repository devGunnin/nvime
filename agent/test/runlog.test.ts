import assert from 'node:assert/strict';
import { appendFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { isTerminal, lastSeqOf, MAX_EVENT_BYTES, readEventsAfter, RunLog } from '../src/runlog.js';

let root = '';
let path = '';

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-runlog-'));
  path = join(root, 'events.ndjson');
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe('RunLog', () => {
  it('numbers events from one and reads them back in order', () => {
    const log = new RunLog(path);
    log.append('big.delta', { text: 'one' });
    log.append('big.tool', { tool: 'Write', summary: 'wrote tool.py' });
    log.close();

    const events = readEventsAfter(path, 0);
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

    const tail = readEventsAfter(path, 1);
    assert.deepEqual(tail.map((event) => event.params.text), ['b', 'c']);
    assert.deepEqual(readEventsAfter(path, 1), tail, 'an attach at the same offset is idempotent');
    assert.deepEqual(readEventsAfter(path, 3), [], 'nothing follows the last event');
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

    const events = readEventsAfter(path, 0);
    assert.equal(events.length, 1);
    assert.equal(events[0]?.params.text, 'before');
  });

  it('truncates one enormous delta instead of writing a line every replay pays for', () => {
    const log = new RunLog(path);
    log.append('big.delta', { text: 'x'.repeat(MAX_EVENT_BYTES * 2) });
    log.close();

    const line = readFileSync(path, 'utf8').trim();
    assert.ok(Buffer.byteLength(line, 'utf8') <= MAX_EVENT_BYTES, 'the line is bounded');
    const event = readEventsAfter(path, 0)[0];
    assert.equal(event?.params.truncated, true, 'and says it was cut');
  });

  it('refuses to append after it is closed rather than dropping the event', () => {
    const log = new RunLog(path);
    log.close();
    assert.throws(() => log.append('big.delta', { text: 'lost' }), /closed/);
  });

  it('reads an absent log as empty — a session that has never been built', () => {
    assert.deepEqual(readEventsAfter(join(root, 'nothing.ndjson'), 0), []);
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
    assert.deepEqual(readEventsAfter(path, 0), []);
  });
});
