import type { DiffHunk, ParsedDiff } from './unidiff.js';

/**
 * Turning a captured diff into review threads.
 *
 * Two invariants hold no matter what the triage turn returns, and both are
 * enforced here rather than trusted: every hunk lands in exactly ONE block,
 * and a hunk the model forgot becomes an open block rather than disappearing.
 * A reviewer who is never shown a change cannot have reviewed it.
 */

export type BlockState = 'open' | 'resolved';

export interface TriageBlock {
  id: string;
  title: string;
  /** Derived from the hunks, never taken from the model: one source of truth. */
  files: string[];
  hunkIds: string[];
  /** True when the reader has to understand it; false for mechanical churn. */
  substantial: boolean;
  rationale: string;
  state: BlockState;
  /** A trivial block the reviewer re-opened; it must not auto-resolve again. */
  reopened: boolean;
  /** Content hashes of this block's hunks, in hunk order. */
  signatures: string[];
}

/** What the triage turn is asked to return. Enforced by the SDK, then re-checked. */
export const TRIAGE_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['blocks'],
  properties: {
    blocks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'hunkIds', 'substantial', 'rationale'],
        properties: {
          title: { type: 'string', description: 'a few words naming the change' },
          hunkIds: { type: 'array', items: { type: 'string' } },
          substantial: {
            type: 'boolean',
            description: 'true when a reader must understand it: logic, behavior, contracts',
          },
          rationale: { type: 'string', description: 'one sentence on why it is grouped and rated this way' },
        },
      },
    },
  },
};

/** A grouping before it has been checked against the diff it claims to cover. */
export interface RawBlock {
  title: string;
  hunkIds: string[];
  substantial: boolean;
  rationale: string;
}

/**
 * The model's blocks, or null when the structured turn returned something that
 * is not a block list. Null is the caller's signal to fall back — never a
 * partially-understood grouping, which would look authoritative and be wrong.
 */
export function parseTriageOutput(raw: unknown): RawBlock[] | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const blocks = (raw as { blocks?: unknown }).blocks;
  if (!Array.isArray(blocks)) return null;
  const out: RawBlock[] = [];
  for (const entry of blocks) {
    if (typeof entry !== 'object' || entry === null) continue;
    const block = entry as Record<string, unknown>;
    const ids = Array.isArray(block.hunkIds)
      ? block.hunkIds.filter((id): id is string => typeof id === 'string' && id !== '')
      : [];
    if (ids.length === 0) continue;
    out.push({
      title: typeof block.title === 'string' && block.title !== '' ? block.title : 'untitled change',
      hunkIds: ids,
      substantial: block.substantial !== false,
      rationale: typeof block.rationale === 'string' ? block.rationale : '',
    });
  }
  return out.length === 0 ? null : out;
}

/** One block per file, everything substantial. What a failed triage turn gets. */
export function fallbackBlocks(diff: ParsedDiff): RawBlock[] {
  return diff.files.map((file) => ({
    title: file.path,
    hunkIds: file.hunks.map((hunk) => hunk.id),
    substantial: true,
    rationale: 'triage did not return a grouping, so this file is one block to read in full',
  }));
}

/**
 * The model's grouping, made safe: unknown ids dropped, a hunk claimed twice
 * kept by its first claimant, empty blocks removed, and everything left over
 * gathered into one substantial `unsorted` block.
 *
 * @throws when the result would not cover the diff exactly once — that is a
 *   bug in this function, not bad model output, and must not ship silently.
 */
export function normalizeBlocks(raw: readonly RawBlock[], diff: ParsedDiff): TriageBlock[] {
  const byId = new Map(diff.hunks.map((hunk) => [hunk.id, hunk]));
  const claimed = new Set<string>();
  const blocks: TriageBlock[] = [];

  for (const entry of raw) {
    const hunks: DiffHunk[] = [];
    for (const id of entry.hunkIds) {
      const hunk = byId.get(id);
      if (hunk === undefined || claimed.has(id)) continue;
      claimed.add(id);
      hunks.push(hunk);
    }
    if (hunks.length === 0) continue;
    blocks.push(makeBlock(`b${blocks.length + 1}`, entry.title, entry.substantial, entry.rationale, hunks));
  }

  const missed = diff.hunks.filter((hunk) => !claimed.has(hunk.id));
  if (missed.length > 0) {
    blocks.push(
      makeBlock(
        `b${blocks.length + 1}`,
        'unsorted',
        true,
        'triage did not place these hunks, so they are shown in full',
        missed,
      ),
    );
  }

  assertCoversExactlyOnce(blocks, diff);
  return blocks;
}

function makeBlock(
  id: string,
  title: string,
  substantial: boolean,
  rationale: string,
  hunks: readonly DiffHunk[],
): TriageBlock {
  const files: string[] = [];
  for (const hunk of hunks) if (!files.includes(hunk.file)) files.push(hunk.file);
  return {
    id,
    title,
    files,
    hunkIds: hunks.map((hunk) => hunk.id),
    substantial,
    rationale,
    // Trivia auto-resolves but stays on screen; substance starts open.
    state: substantial ? 'open' : 'resolved',
    reopened: false,
    signatures: hunks.map((hunk) => hunk.signature),
  };
}

function assertCoversExactlyOnce(blocks: readonly TriageBlock[], diff: ParsedDiff): void {
  const seen = new Set<string>();
  for (const block of blocks) {
    for (const id of block.hunkIds) {
      if (seen.has(id)) throw new Error(`triage assigned hunk ${id} to two blocks`);
      seen.add(id);
    }
  }
  if (seen.size !== diff.hunks.length) {
    throw new Error(`triage covered ${seen.size} of ${diff.hunks.length} hunks`);
  }
}

/**
 * Re-applies review state after a revision re-captured the diff. A block whose
 * content the reviewer has already seen, AT THE SAME RATING, keeps its verdict;
 * anything new, re-rated, or still open comes back open.
 *
 * Deliberately conservative: an unknown key means unreviewed content, so the
 * block opens even if the rest of it was cleared. The rating is part of the key
 * because a re-rating is new information — bytes auto-resolved as trivia in an
 * earlier round must not arrive resolved once triage calls them substantial,
 * which would clear a substantial thread nobody defended and hand the merge
 * predicate a thread the review gate never saw.
 */
export function carryForward(previous: readonly TriageBlock[], next: readonly TriageBlock[]): TriageBlock[] {
  const prior = new Map<string, BlockState>();
  for (const block of previous) {
    for (const signature of block.signatures) {
      const key = priorKey(signature, block.substantial);
      // An open block wins: the same content cleared in one place and open in
      // another has not been cleared.
      if (block.state === 'open' || !prior.has(key)) prior.set(key, block.state);
    }
  }
  return next.map((block) => {
    const carried = carriedState(block, prior);
    if (carried === null) return block;
    return { ...block, state: carried, reopened: carried === 'open' && !block.substantial };
  });
}

function priorKey(signature: string, substantial: boolean): string {
  return `${substantial ? 'sub' : 'triv'}:${signature}`;
}

/** The state a block inherits, or null when any of its content is new to it. */
function carriedState(block: TriageBlock, prior: ReadonlyMap<string, BlockState>): BlockState | null {
  let state: BlockState = 'resolved';
  for (const signature of block.signatures) {
    const seen = prior.get(priorKey(signature, block.substantial));
    if (seen === undefined) return null;
    if (seen === 'open') state = 'open';
  }
  return state;
}

export interface TriageCounts {
  total: number;
  open: number;
  substantial: number;
}

export function countBlocks(blocks: readonly TriageBlock[]): TriageCounts {
  return {
    total: blocks.length,
    open: blocks.filter((block) => block.state === 'open').length,
    substantial: blocks.filter((block) => block.substantial).length,
  };
}
