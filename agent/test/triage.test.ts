import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  carryForward,
  countBlocks,
  fallbackBlocks,
  normalizeBlocks,
  parseTriageOutput,
  TRIVIA_ACK_TITLE,
  withTrivialAck,
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

/** Hunk ids are content hashes, so tests name them by position in the diff. */
const hunkIds = (diff: ReturnType<typeof parseUnifiedDiff>): string[] => diff.hunks.map((hunk) => hunk.id);

describe('normalizeBlocks', () => {
  const diff = diffOf([
    { path: 'a.txt', hunks: 2 },
    { path: 'b.txt', hunks: 1 },
  ]);
  // a.txt hunk 1, a.txt hunk 2, b.txt hunk 1.
  const [a1 = '', a2 = '', b1 = ''] = hunkIds(diff);

  it('keeps a grouping that already covers every hunk exactly once', () => {
    const raw: RawBlock[] = [
      { title: 'core', hunkIds: [a1, b1], substantial: true, rationale: 'logic' },
      { title: 'imports', hunkIds: [a2], substantial: false, rationale: 'mechanical' },
    ];
    const blocks = normalizeBlocks(raw, diff);
    assert.deepEqual(ids(blocks), [[a1, b1], [a2]]);
    assert.deepEqual(blocks[0]?.files, ['a.txt', 'b.txt']);
    assert.equal(blocks[0]?.state, 'open', 'substance starts open');
    assert.equal(blocks[1]?.state, 'resolved', 'trivia auto-resolves but stays listed');
  });

  it('gives a hunk claimed twice to its first claimant only', () => {
    const raw: RawBlock[] = [
      { title: 'first', hunkIds: [a1], substantial: true, rationale: '' },
      { title: 'second', hunkIds: [a1, a2], substantial: true, rationale: '' },
      { title: 'third', hunkIds: [b1], substantial: true, rationale: '' },
    ];
    assert.deepEqual(ids(normalizeBlocks(raw, diff)), [[a1], [a2], [b1]]);
  });

  it('drops ids that are not in the diff, and the block if that empties it', () => {
    const raw: RawBlock[] = [
      { title: 'ghost', hunkIds: ['hdeadbeefdead'], substantial: true, rationale: '' },
      { title: 'real', hunkIds: [a1, a2, b1, 'nope'], substantial: true, rationale: '' },
    ];
    const blocks = normalizeBlocks(raw, diff);
    assert.equal(blocks.length, 1);
    assert.deepEqual(blocks[0]?.hunkIds, [a1, a2, b1]);
  });

  it('gathers hunks triage forgot into one open unsorted block', () => {
    const raw: RawBlock[] = [{ title: 'partial', hunkIds: [a1], substantial: false, rationale: '' }];
    const blocks = normalizeBlocks(raw, diff);
    const unsorted = blocks[blocks.length - 1];
    assert.equal(unsorted?.title, 'unsorted');
    assert.equal(unsorted?.substantial, true, 'unplaced hunks are never auto-resolved');
    assert.deepEqual(unsorted?.hunkIds, [a2, b1]);
  });

  it('covers every hunk exactly once whatever it is handed', () => {
    for (const raw of [
      [],
      [{ title: 'x', hunkIds: [], substantial: true, rationale: '' }],
      [{ title: 'x', hunkIds: [a1, a1, a1], substantial: true, rationale: '' }],
      [{ title: 'x', hunkIds: [b1, a2, a1], substantial: false, rationale: '' }],
    ] satisfies RawBlock[][]) {
      const seen = normalizeBlocks(raw, diff).flatMap((block) => block.hunkIds);
      assert.deepEqual([...seen].sort(), [a1, a2, b1].sort(), `coverage broke for ${JSON.stringify(raw)}`);
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
    const [a1 = '', a2 = '', b1 = ''] = hunkIds(diff);
    const blocks = normalizeBlocks(fallbackBlocks(diff), diff);
    assert.deepEqual(ids(blocks), [[a1, a2], [b1]]);
    assert.ok(blocks.every((block) => block.substantial && block.state === 'open'));
  });
});

describe('carryForward', () => {
  const diff = diffOf([
    { path: 'a.txt', hunks: 1 },
    { path: 'b.txt', hunks: 1 },
  ]);
  const [a1 = '', b1 = ''] = hunkIds(diff);
  const first = normalizeBlocks(
    [
      { title: 'a', hunkIds: [a1], substantial: true, rationale: '' },
      { title: 'b', hunkIds: [b1], substantial: false, rationale: '' },
    ],
    diff,
  );

  it('keeps a cleared verdict when the content is unchanged', () => {
    const cleared = first.map((block) => ({ ...block, state: 'resolved' as const }));
    const next = normalizeBlocks(
      [
        { title: 'a again', hunkIds: [a1], substantial: true, rationale: '' },
        { title: 'b again', hunkIds: [b1], substantial: false, rationale: '' },
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
      [{ title: 'mixed', hunkIds: hunkIds(revised), substantial: true, rationale: '' }],
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
        { title: 'a', hunkIds: [a1], substantial: true, rationale: '' },
        { title: 'b', hunkIds: [b1], substantial: false, rationale: '' },
      ],
      diff,
    );
    const carried = carryForward(reopened, next);
    assert.equal(carried[1]?.state, 'open');
    assert.equal(carried[1]?.reopened, true);
  });

  it('never auto-resolves a thread the latest triage rated substantial', () => {
    // Round 1 called these bytes formatting, so they auto-resolved. Round 2
    // corrects itself — "this import change actually alters behavior" — and the
    // correction must not arrive already cleared: nobody defended it, and
    // `mergeable` is built on exactly this flag.
    const trivial = normalizeBlocks([{ title: 'churn', hunkIds: [a1], substantial: false, rationale: '' }], diff);
    assert.equal(trivial[0]?.state, 'resolved');
    const rerated = normalizeBlocks([{ title: 'churn', hunkIds: [a1], substantial: true, rationale: '' }], diff);
    const carried = carryForward(trivial, rerated);
    assert.equal(carried[0]?.substantial, true);
    assert.equal(carried[0]?.state, 'open', 'a re-rating is new information, not a carried verdict');
  });

  it('does not carry a substantial clearance down onto the same bytes rated trivial', () => {
    const cleared = normalizeBlocks(
      [{ title: 'core', hunkIds: [a1], substantial: true, rationale: '' }],
      diff,
    ).map((block) => ({ ...block, state: 'resolved' as const }));
    const next = normalizeBlocks([{ title: 'core', hunkIds: [a1], substantial: false, rationale: '' }], diff);
    // Trivia auto-resolves anyway, so the verdict is the same; what matters is
    // that it came from this round's rating and not from the other one.
    assert.equal(carryForward(cleared, next)[0]?.state, 'resolved');
    assert.equal(carryForward(cleared, next)[0]?.reopened, false);
  });

  it('counts what is left to review', () => {
    assert.deepEqual(countBlocks(first), { total: 2, open: 1, substantial: 1, defended: 0 });
  });
});

describe('withTrivialAck', () => {
  const diff = diffOf([{ path: 'a.txt', hunks: 2 }]);
  const [a1 = '', a2 = ''] = hunkIds(diff);
  const trivia = normalizeBlocks(
    [{ title: 'churn', hunkIds: [a1, a2], substantial: false, rationale: '' }],
    diff,
  );

  it('leaves a change nobody has to defend one thread that is still open', () => {
    const blocks = withTrivialAck(trivia, diff.hunks.length, true);
    assert.equal(blocks.length, 2);
    const ack = blocks[1];
    assert.equal(ack?.title, TRIVIA_ACK_TITLE);
    assert.equal(ack?.state, 'open');
    assert.equal(ack?.substantial, false, 'there is no hunk here to grade an answer about');
    assert.deepEqual(ack?.hunkIds, [], 'and it hides none of the diff behind itself');
    assert.deepEqual(countBlocks(blocks), { total: 2, open: 1, substantial: 0, defended: 0 });
  });

  it('adds nothing when a thread already has to be defended, or when nothing changed', () => {
    const substantial = normalizeBlocks([{ title: 'core', hunkIds: [a1, a2], substantial: true, rationale: '' }], diff);
    assert.deepEqual(withTrivialAck(substantial, diff.hunks.length, true), substantial);
    assert.deepEqual(withTrivialAck([], 0, true), []);
  });

  it('adds nothing on `vibe`, the one difficulty that runs no gate at all', () => {
    assert.deepEqual(withTrivialAck(trivia, diff.hunks.length, false), trivia);
  });

  it('asks again after a re-capture: it carries no signature, so it cannot be carried', () => {
    const acknowledged = withTrivialAck(trivia, diff.hunks.length, true).map((block) =>
      block.hunkIds.length === 0 ? { ...block, state: 'resolved' as const } : block,
    );
    const recaptured = withTrivialAck(carryForward(acknowledged, trivia), diff.hunks.length, true);
    assert.equal(recaptured[1]?.state, 'open', 'new bytes need the acknowledgment again');
  });
});
