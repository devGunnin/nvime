import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { readSnapshot, sameSnapshot, snapshotBytes } from '../src/snapshot.js';

describe('readSnapshot', () => {
  let dir = '';
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'nvime-snapshot-'));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('reads a text file as text', () => {
    const path = join(dir, 'a.txt');
    writeFileSync(path, 'one\ntwo\n');
    assert.deepEqual(readSnapshot(path), { kind: 'text', text: 'one\ntwo\n' });
  });

  it('reports a file that is not there as absent, not empty', () => {
    assert.deepEqual(readSnapshot(join(dir, 'missing.txt')), { kind: 'absent' });
  });

  it('reports a file with a NUL byte as binary rather than mangling it', () => {
    const path = join(dir, 'a.bin');
    writeFileSync(path, Buffer.from([0x61, 0x00, 0x62]));
    assert.deepEqual(readSnapshot(path), { kind: 'opaque', reason: 'binary', bytes: 3 });
  });

  it('refuses a file whose bytes are not valid UTF-8, rather than mangling them', () => {
    const path = join(dir, 'latin1.txt');
    // 0xE9 is `é` in latin-1 and an invalid lone byte in UTF-8: decoding it
    // yields U+FFFD, and a snapshot that no longer describes the file's bytes
    // would have the editor write the mangled version back over it.
    writeFileSync(path, Buffer.from([0x63, 0xe9, 0x0a]));
    assert.deepEqual(readSnapshot(path), { kind: 'opaque', reason: 'binary', bytes: 3 });
  });

  it('keeps valid multi-byte UTF-8 as text', () => {
    const path = join(dir, 'utf8.txt');
    writeFileSync(path, 'héllo ☃\n');
    assert.deepEqual(readSnapshot(path), { kind: 'text', text: 'héllo ☃\n' });
  });

  it('refuses to carry a file over the size ceiling', () => {
    const path = join(dir, 'big.txt');
    writeFileSync(path, 'x'.repeat(4096));
    assert.deepEqual(readSnapshot(path, 1024), { kind: 'opaque', reason: 'oversize', bytes: 4096 });
  });

  it('reports a directory as unreadable rather than throwing', () => {
    const path = join(dir, 'sub');
    mkdirSync(path);
    assert.deepEqual(readSnapshot(path), { kind: 'opaque', reason: 'unreadable', bytes: 0 });
  });
});

describe('sameSnapshot', () => {
  it('compares text by content and treats absence as its own state', () => {
    assert.equal(sameSnapshot({ kind: 'text', text: 'a' }, { kind: 'text', text: 'a' }), true);
    assert.equal(sameSnapshot({ kind: 'text', text: 'a' }, { kind: 'text', text: 'b' }), false);
    assert.equal(sameSnapshot({ kind: 'absent' }, { kind: 'absent' }), true);
    assert.equal(sameSnapshot({ kind: 'absent' }, { kind: 'text', text: '' }), false);
  });

  it('never calls two unread files equal', () => {
    const opaque = { kind: 'opaque', reason: 'binary', bytes: 8 } as const;
    assert.equal(sameSnapshot(opaque, opaque), false, 'nothing was read, so nothing can be claimed');
  });
});

describe('snapshotBytes', () => {
  it('counts only what is actually retained', () => {
    assert.equal(snapshotBytes({ kind: 'text', text: 'héllo' }), 6);
    assert.equal(snapshotBytes({ kind: 'absent' }), 0);
    assert.equal(snapshotBytes({ kind: 'opaque', reason: 'oversize', bytes: 99 }), 0);
  });
});
