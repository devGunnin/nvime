import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  carryForward,
  countBlocks,
  fallbackBlocks,
  normalizeBlocks,
  parseTriageOutput,
  type RawBlock,
  type TriageBlock,
} from '../src/triage.js';
import { parseUnifiedDiff } from '../src/unidiff.js';

function diffOf(files: Array<{ path: string; hunks: number }>): ReturnType<typeof parseUnifiedDiff> {
  const lines: string[] = [];
  for (const file of files) {
    lines.push(`diff --git a/${file.path} b/${file.path}`, `--- a/${file.path}`, `+++ b/${file.path}`);
    for (let i = 0; i < file.hunks; i += 1) {
      lines.push(`@@ -${i + 1} +${i + 1} @@`, `-old${i}-${file.path}`, `+new${i}-${file.path}`);
    }
  }
  return parseUnifiedDiff(lines.join('\n') + '\n');
}

const ids = (blocks: readonly TriageBlock[]): string[][] => blocks.map((block) => block.hunkIds);

describe('normalizeBlocks', () => {
  const diff = diffOf([
    { path: 'a.txt', hunks: 2 },
    { path: 'b.txt', hunks: 1 },
  ]);

  it('keeps a grouping that already covers every hunk exactly once', () => {
    const raw: RawBlock[] = [
      { title: 'core', hunkIds: ['h1.1', 'h2.1'], substantial: true, rationale: 'logic' },
      { title: 'imports', hunkIds: ['h1.2'], substantial: false, rationale: 'mechanical' },
    ];
    const blocks = normalizeBlocks(raw, diff);
    assert.deepEqual(ids(blocks), [['h1.1', 'h2.1'], ['h1.2']]);
    assert.deepEqual(blocks[0]?.files, ['a.txt', 'b.txt']);
    assert.equal(blocks[0]?.state, 'open', 'substance starts open');
    assert.equal(blocks[1]?.state, 'resolved', 'trivia auto-resolves but stays listed');
  });

  it('gives a hunk claimed twice to its first claimant only', () => {
    const raw: RawBlock[] = [
      { title: 'first', hunkIds: ['h1.1'], substantial: true, rationale: '' },
      { title: 'second', hunkIds: ['h1.1', 'h1.2'], substantial: true, rationale: '' },
      { title: 'third', hunkIds: ['h2.1'], substantial: true, rationale: '' },
    ];
    assert.deepEqual(ids(normalizeBlocks(raw, diff)), [['h1.1'], ['h1.2'], ['h2.1']]);
  });

  it('drops ids that are not in the diff, and the block if that empties it', () => {
    const raw: RawBlock[] = [
      { title: 'ghost', hunkIds: ['h9.9'], substantial: true, rationale: '' },
      { title: 'real', hunkIds: ['h1.1', 'h1.2', 'h2.1', 'nope'], substantial: true, rationale: '' },
    ];
    const blocks = normalizeBlocks(raw, diff);
    assert.equal(blocks.length, 1);
    assert.deepEqual(blocks[0]?.hunkIds, ['h1.1', 'h1.2', 'h2.1']);
  });

  it('gathers hunks triage forgot into one open unsorted block', () => {
    const raw: RawBlock[] = [{ title: 'partial', hunkIds: ['h1.1'], substantial: false, rationale: '' }];
    const blocks = normalizeBlocks(raw, diff);
    const unsorted = blocks[blocks.length - 1];
    assert.equal(unsorted?.title, 'unsorted');
    assert.equal(unsorted?.substantial, true, 'unplaced hunks are never auto-resolved');
    assert.deepEqual(unsorted?.hunkIds, ['h1.2', 'h2.1']);
  });

  it('covers every hunk exactly once whatever it is handed', () => {
    for (const raw of [
      [],
      [{ title: 'x', hunkIds: [], substantial: true, rationale: '' }],
      [{ title: 'x', hunkIds: ['h1.1', 'h1.1', 'h1.1'], substantial: true, rationale: '' }],
      [{ title: 'x', hunkIds: ['h2.1', 'h1.2', 'h1.1'], substantial: false, rationale: '' }],
    ] satisfies RawBlock[][]) {
      const seen = normalizeBlocks(raw, diff).flatMap((block) => block.hunkIds);
      assert.deepEqual([...seen].sort(), ['h1.1', 'h1.2', 'h2.1'], `coverage broke for ${JSON.stringify(raw)}`);
    }
  });
});

describe('parseTriageOutput', () => {
  it('returns null for anything that is not a block list', () => {
    for (const raw of [undefined, null, 42, 'blocks', {}, { blocks: 'nope' }, { blocks: [] }, { blocks: [1, 2] }]) {
      assert.equal(parseTriageOutput(raw), null, `accepted ${JSON.stringify(raw)}`);
    }
  });

  it('drops entries with no usable hunk ids and keeps the rest', () => {
    const parsed = parseTriageOutput({
      blocks: [
        { title: 'empty', hunkIds: [], substantial: true, rationale: '' },
        { title: '', hunkIds: ['h1.1', 7, ''], substantial: false, rationale: 5 },
      ],
    });
    assert.deepEqual(parsed, [
      { title: 'untitled change', hunkIds: ['h1.1'], substantial: false, rationale: '' },
    ]);
  });

  it('treats a missing substantial flag as substantial', () => {
    const parsed = parseTriageOutput({ blocks: [{ title: 't', hunkIds: ['h1.1'] }] });
    assert.equal(parsed?.[0]?.substantial, true);
  });
});

describe('fallbackBlocks', () => {
  it('makes one substantial block per file when triage produced nothing', () => {
    const diff = diffOf([
      { path: 'a.txt', hunks: 2 },
      { path: 'b.txt', hunks: 1 },
    ]);
    const blocks = normalizeBlocks(fallbackBlocks(diff), diff);
    assert.deepEqual(ids(blocks), [['h1.1', 'h1.2'], ['h2.1']]);
    assert.ok(blocks.every((block) => block.substantial && block.state === 'open'));
  });
});

describe('carryForward', () => {
  const diff = diffOf([
    { path: 'a.txt', hunks: 1 },
    { path: 'b.txt', hunks: 1 },
  ]);
  const first = normalizeBlocks(
    [
      { title: 'a', hunkIds: ['h1.1'], substantial: true, rationale: '' },
      { title: 'b', hunkIds: ['h2.1'], substantial: false, rationale: '' },
    ],
    diff,
  );

  it('keeps a cleared verdict when the content is unchanged', () => {
    const cleared = first.map((block) => ({ ...block, state: 'resolved' as const }));
    const next = normalizeBlocks(
      [
        { title: 'a again', hunkIds: ['h1.1'], substantial: true, rationale: '' },
        { title: 'b again', hunkIds: ['h2.1'], substantial: false, rationale: '' },
      ],
      diff,
    );
    assert.deepEqual(
      carryForward(cleared, next).map((block) => block.state),
      ['resolved', 'resolved'],
    );
  });

  it('opens a block whose content is new, even alongside cleared content', () => {
    const revised = diffOf([
      { path: 'a.txt', hunks: 1 },
      { path: 'c.txt', hunks: 1 },
    ]);
    const cleared = first.map((block) => ({ ...block, state: 'resolved' as const }));
    const next = normalizeBlocks(
      [{ title: 'mixed', hunkIds: ['h1.1', 'h2.1'], substantial: true, rationale: '' }],
      revised,
    );
    assert.equal(carryForward(cleared, next)[0]?.state, 'open', 'unseen content must be reviewed');
  });

  it('keeps a re-opened trivial block open instead of auto-resolving it again', () => {
    const reopened = first.map((block) =>
      block.substantial ? block : { ...block, state: 'open' as const, reopened: true },
    );
    const next = normalizeBlocks(
      [
        { title: 'a', hunkIds: ['h1.1'], substantial: true, rationale: '' },
        { title: 'b', hunkIds: ['h2.1'], substantial: false, rationale: '' },
      ],
      diff,
    );
    const carried = carryForward(reopened, next);
    assert.equal(carried[1]?.state, 'open');
    assert.equal(carried[1]?.reopened, true);
  });

  it('counts what is left to review', () => {
    assert.deepEqual(countBlocks(first), { total: 2, open: 1, substantial: 1 });
  });
});
