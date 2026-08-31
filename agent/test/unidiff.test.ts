import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { parseUnifiedDiff, renderForTriage, signatureOf } from '../src/unidiff.js';

describe('parseUnifiedDiff', () => {
  it('reads a modified file into hunks with 1-based line spans', () => {
    const diff = [
      'diff --git a/pool.py b/pool.py',
      'index 1111111..2222222 100644',
      '--- a/pool.py',
      '+++ b/pool.py',
      '@@ -1,3 +1,4 @@',
      ' import time',
      '-def next_delay(attempt):',
      '+def next_delay(self, attempt):',
      '+    base = min(self.cap, 2 ** attempt)',
      '     return 0',
      '',
    ].join('\n');
    const parsed = parseUnifiedDiff(diff);
    assert.equal(parsed.files.length, 1);
    const file = parsed.files[0];
    assert.ok(file !== undefined);
    assert.equal(file.path, 'pool.py');
    assert.equal(file.status, 'modified');
    assert.equal(file.hunks.length, 1);
    const hunk = file.hunks[0];
    assert.ok(hunk !== undefined);
    assert.deepEqual(
      { oldStart: hunk.oldStart, oldCount: hunk.oldCount, newStart: hunk.newStart, newCount: hunk.newCount },
      { oldStart: 1, oldCount: 3, newStart: 1, newCount: 4 },
    );
    assert.equal(hunk.id, `h${hunk.signature.slice(0, 12)}`, 'the id addresses the content');
    assert.equal(hunk.lines.length, 5);
    assert.equal(hunk.synthetic, false);
  });

  it('ends a hunk by its promised line counts, not by the next @@ it can see', () => {
    // The hunk BODY contains a full diff — a fixture, the ordinary case in a
    // test suite. A parser that splits on `@@`/`---` cuts the hunk in half.
    const diff = [
      'diff --git a/fixture.txt b/fixture.txt',
      '--- a/fixture.txt',
      '+++ b/fixture.txt',
      '@@ -1,2 +1,5 @@',
      ' keep',
      '+--- a/inner',
      '++++ b/inner',
      '+@@ -1 +1 @@',
      ' tail',
      'diff --git a/other.txt b/other.txt',
      '--- a/other.txt',
      '+++ b/other.txt',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      '',
    ].join('\n');
    const parsed = parseUnifiedDiff(diff);
    assert.deepEqual(
      parsed.files.map((file) => file.path),
      ['fixture.txt', 'other.txt'],
    );
    assert.equal(parsed.hunks.length, 2);
    assert.equal(parsed.files[0]?.hunks[0]?.lines.length, 5);
  });

  it('classifies additions, deletions and renames from their headers', () => {
    const diff = [
      'diff --git a/new.txt b/new.txt',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/new.txt',
      '@@ -0,0 +1,1 @@',
      '+hello',
      'diff --git a/gone.txt b/gone.txt',
      'deleted file mode 100644',
      '--- a/gone.txt',
      '+++ /dev/null',
      '@@ -1,1 +0,0 @@',
      '-bye',
      'diff --git a/old.txt b/renamed.txt',
      'similarity index 100%',
      'rename from old.txt',
      'rename to renamed.txt',
      '',
    ].join('\n');
    const parsed = parseUnifiedDiff(diff);
    assert.deepEqual(
      parsed.files.map((file) => [file.path, file.status]),
      [
        ['new.txt', 'added'],
        ['gone.txt', 'deleted'],
        ['renamed.txt', 'renamed'],
      ],
    );
    assert.equal(parsed.files[1]?.path, 'gone.txt', 'a deletion is named by its old path');
  });

  it('gives a change git described without a hunk one anyway', () => {
    const diff = [
      'diff --git a/logo.png b/logo.png',
      'index 1111111..2222222 100644',
      'Binary files a/logo.png and b/logo.png differ',
      'diff --git a/old.txt b/new.txt',
      'similarity index 100%',
      'rename from old.txt',
      'rename to new.txt',
      '',
    ].join('\n');
    const parsed = parseUnifiedDiff(diff);
    assert.equal(parsed.hunks.length, 2, 'neither file may vanish from the review');
    assert.ok(parsed.hunks.every((hunk) => hunk.synthetic));
    assert.match(parsed.hunks[0]?.lines[0] ?? '', /binary/i);
  });

  it('does not count the no-newline marker against either side', () => {
    const diff = [
      'diff --git a/a.txt b/a.txt',
      '--- a/a.txt',
      '+++ b/a.txt',
      '@@ -1 +1 @@',
      '-one',
      '\\ No newline at end of file',
      '+two',
      'diff --git a/b.txt b/b.txt',
      '--- a/b.txt',
      '+++ b/b.txt',
      '@@ -1 +1 @@',
      '-x',
      '+y',
      '',
    ].join('\n');
    const parsed = parseUnifiedDiff(diff);
    assert.equal(parsed.files.length, 2);
    assert.equal(parsed.files[0]?.hunks[0]?.lines.length, 3);
  });

  it('decodes a C-quoted path with a space in it', () => {
    const diff = [
      'diff --git "a/my file.txt" "b/my file.txt"',
      '--- "a/my file.txt"',
      '+++ "b/my file.txt"',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      '',
    ].join('\n');
    assert.equal(parseUnifiedDiff(diff).files[0]?.path, 'my file.txt');
  });

  it('gives identical content the same signature and changed content a different one', () => {
    const same = signatureOf('a.txt', [' ctx', '+one']);
    assert.equal(same, signatureOf('a.txt', [' ctx', '+one']));
    assert.notEqual(same, signatureOf('a.txt', [' ctx', '+two']));
    assert.notEqual(same, signatureOf('b.txt', [' ctx', '+one']), 'the same edit in another file is another hunk');
  });

  it('locates each hunk in the diff text so the editor can slice it back out', () => {
    const diff = [
      'diff --git a/a.txt b/a.txt',
      '--- a/a.txt',
      '+++ b/a.txt',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      'diff --git a/c.txt b/c.txt',
      '--- a/c.txt',
      '+++ b/c.txt',
      '@@ -1 +1 @@',
      '-c',
      '+d',
      '',
    ].join('\n');
    const lines = diff.split('\n');
    for (const hunk of parseUnifiedDiff(diff).hunks) {
      const sliced = lines.slice(hunk.offset, hunk.offset + hunk.lineCount);
      assert.deepEqual(sliced, [hunk.header, ...hunk.lines], hunk.id);
    }
  });

  it('keeps a path with a space out of the trailing tab git appends to it', () => {
    // Real `git diff` output: an unquoted path containing a space is followed
    // by a literal TAB on the `---`/`+++` lines.
    const diff = [
      'diff --git a/space name.txt b/space name.txt',
      'new file mode 100644',
      '--- /dev/null',
      '+++ b/space name.txt\t',
      '@@ -0,0 +1 @@',
      '+hello',
      '',
    ].join('\n');
    const file = parseUnifiedDiff(diff).files[0];
    assert.equal(file?.path, 'space name.txt', 'a tab in the path makes the file unopenable and mislabels the thread');
    assert.equal(parseUnifiedDiff(diff).hunks[0]?.file, 'space name.txt');
  });

  it('keeps a tab escaped inside a quoted path', () => {
    const diff = [
      'diff --git "a/tab\\tname.txt" "b/tab\\tname.txt"',
      '--- "a/tab\\tname.txt"',
      '+++ "b/tab\\tname.txt"',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      '',
    ].join('\n');
    assert.equal(parseUnifiedDiff(diff).files[0]?.path, 'tab\tname.txt');
  });

  it('addresses hunks by content, so an id cannot follow a slot into another hunk', () => {
    const one = (path: string, body: string): string =>
      [`diff --git a/${path} b/${path}`, `--- a/${path}`, `+++ b/${path}`, '@@ -1 +1 @@', `+${body}`, ''].join('\n');
    const before = parseUnifiedDiff(one('a.txt', 'alpha') + one('b.txt', 'beta'));
    // A revision inserts a file ahead of them: positional ids would slide.
    const after = parseUnifiedDiff(one('a.txt', 'alpha') + one('aaa.txt', 'secret') + one('b.txt', 'beta'));
    const idOf = (parsed: typeof before, file: string): string | undefined =>
      parsed.hunks.find((hunk) => hunk.file === file)?.id;
    assert.equal(idOf(before, 'a.txt'), idOf(after, 'a.txt'), 'unchanged content keeps its id');
    assert.equal(idOf(before, 'b.txt'), idOf(after, 'b.txt'), 'and does not shift with the file ahead of it');
    const stale = idOf(before, 'b.txt');
    const resolved = after.hunks.find((hunk) => hunk.id === stale);
    assert.equal(resolved?.file, 'b.txt', 'an id never resolves to a hunk that is not its content');
    assert.equal(new Set(after.hunks.map((hunk) => hunk.id)).size, 3, 'ids stay unique within a capture');
  });

  it('distinguishes two byte-identical hunks in one file', () => {
    const diff = [
      'diff --git a/dup.txt b/dup.txt',
      '--- a/dup.txt',
      '+++ b/dup.txt',
      '@@ -1 +1 @@',
      '-old',
      '+same',
      '@@ -9 +9 @@',
      '-old',
      '+same',
      '',
    ].join('\n');
    const hunks = parseUnifiedDiff(diff).hunks;
    assert.equal(hunks.length, 2);
    assert.equal(hunks[0]?.signature, hunks[1]?.signature, 'identical content, identical signature');
    assert.notEqual(hunks[0]?.id, hunks[1]?.id, 'but each hunk still needs its own id');
  });

  it('empty input parses to no files rather than throwing', () => {
    assert.deepEqual(parseUnifiedDiff(''), { files: [], hunks: [] });
  });
});

describe('renderForTriage', () => {
  const diff = parseUnifiedDiff(
    [
      'diff --git a/a.txt b/a.txt',
      '--- a/a.txt',
      '+++ b/a.txt',
      '@@ -1 +1 @@',
      '-a',
      '+b',
      'diff --git a/c.txt b/c.txt',
      '--- a/c.txt',
      '+++ b/c.txt',
      '@@ -1 +1 @@',
      '-c',
      '+d',
      '',
    ].join('\n'),
  );

  const [first = '', second = ''] = diff.hunks.map((hunk) => hunk.id);

  it('labels every hunk with the id triage answers in', () => {
    const rendered = renderForTriage(diff, 1024);
    assert.equal(rendered.truncated, false);
    assert.ok(rendered.text.includes(`[${first}] modified a.txt`), rendered.text);
    assert.ok(rendered.text.includes(`[${second}] modified c.txt`), rendered.text);
  });

  it('says so when the diff did not fit', () => {
    const rendered = renderForTriage(diff, 60);
    assert.equal(rendered.truncated, true);
    assert.ok(!rendered.text.includes(second));
  });
});
