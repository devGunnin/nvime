import type { GateRound } from './gate.js';
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
  /**
   * The comprehension gate's record for this thread: every answer and what the
   * grader said about it, oldest first. Empty until the reader defends it.
   */
  rounds: GateRound[];
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
 * `unshownIds` names hunks the triage turn was never shown at all (a diff
 * that exceeded the triage window) — kept apart from hunks it saw and did not
 * place, so the block's rationale says which actually happened rather than
 * blaming the model for a hunk it never had the chance to sort.
 *
 * `armed` is the session's gate: false (difficulty `vibe`) means substantial
 * threads start cleared, because there is nothing to defend them to. It is a
 * parameter rather than a post-pass so a block is never briefly open in a
 * session that runs no gate.
 *
 * @throws when the result would not cover the diff exactly once — that is a
 *   bug in this function, not bad model output, and must not ship silently.
 */
export function normalizeBlocks(
  raw: readonly RawBlock[],
  diff: ParsedDiff,
  unshownIds: ReadonlySet<string> = new Set(),
  armed = true,
): TriageBlock[] {
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
    blocks.push(makeBlock(`b${blocks.length + 1}`, entry.title, entry.substantial, entry.rationale, hunks, armed));
  }

  const missed = diff.hunks.filter((hunk) => !claimed.has(hunk.id));
  if (missed.length > 0) {
    const notShown = missed.filter((hunk) => unshownIds.has(hunk.id)).length;
    const rationale = unsortedRationale(notShown, missed.length - notShown);
    blocks.push(makeBlock(`b${blocks.length + 1}`, 'unsorted', true, rationale, missed, armed));
  }

  assertCoversExactlyOnce(blocks, diff);
  return blocks;
}

/** What actually happened to the hunks in the `unsorted` block — never a guess. */
function unsortedRationale(notShown: number, unplaced: number): string {
  if (notShown > 0 && unplaced > 0) {
    return (
      `${notShown} hunk(s) exceeded the triage window and were not shown; ` +
      `${unplaced} more were shown but triage did not place them`
    );
  }
  if (notShown > 0) return `${notShown} hunk(s) exceeded the triage window and were not shown`;
  return 'triage did not place these hunks, so they are shown in full';
}

function makeBlock(
  id: string,
  title: string,
  substantial: boolean,
  rationale: string,
  hunks: readonly DiffHunk[],
  armed: boolean,
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
    // Trivia auto-resolves but stays on screen; substance starts open, unless
    // this session runs no gate at all.
    state: substantial && armed ? 'open' : 'resolved',
    reopened: false,
    signatures: hunks.map((hunk) => hunk.signature),
    rounds: [],
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

export const TRIVIA_ACK_TITLE = 'everything was rated trivial — open the diff and confirm';

/**
 * The acknowledgment a change nobody has to defend still needs.
 *
 * A triage turn that rates every thread trivial produces a session that is
 * mergeable the moment it is triaged, `0/0 defended`, with no answer ever
 * typed — and the diff that turn read was written by the build agent, so a
 * comment aimed at it disarms the whole gate. So an all-trivia change gets one
 * more thread, open, which the reader clears with `X` after looking at the diff
 * themselves. It carries no hunks, so it never hides one; it has no signature,
 * so a re-capture always asks again; and there is no setting that removes it —
 * `vibe` is the only difficulty that runs no gate at all, and it is chosen per
 * change rather than being a way to skip this one.
 */
export function withTrivialAck(blocks: TriageBlock[], hunkCount: number, armed: boolean): TriageBlock[] {
  if (!armed || hunkCount === 0) return blocks;
  if (blocks.some((block) => block.substantial)) return blocks;
  return [
    ...blocks,
    {
      id: `b${blocks.length + 1}`,
      title: TRIVIA_ACK_TITLE,
      files: [],
      hunkIds: [],
      // Not substantial: there is no hunk here to defend, and the gate grades
      // answers about hunks. What it wants is the reader's own eyes on the diff.
      substantial: false,
      rationale: 'triage found nothing a reader must understand, so nothing was graded — read the diff and clear this',
      state: 'open',
      reopened: false,
      signatures: [],
      rounds: [],
    },
  ];
}

/** What one prior thread contributes to a re-captured one. */
interface PriorEntry {
  state: BlockState;
  rounds: GateRound[];
  /** Which prior thread this content belonged to, so a regrouping is visible. */
  owner: number;
}

/**
 * Re-applies review state after a revision re-captured the diff. A block whose
 * content the reviewer has already seen, AT THE SAME RATING, keeps its verdict
 * and the defense that earned it; anything new, re-rated, or still open comes
 * back open.
 *
 * Deliberately conservative: an unknown key means unreviewed content, so the
 * block opens even if the rest of it was cleared. The rating is part of the key
 * because a re-rating is new information — bytes auto-resolved as trivia in an
 * earlier round must not arrive resolved once triage calls them substantial,
 * which would clear a substantial thread nobody defended and hand the merge
 * predicate a thread the review gate never saw.
 *
 * The defense carries only when the thread is the SAME thread: a block built
 * out of two earlier ones keeps its cleared state but starts a fresh record,
 * because no single answer covers the content it now holds.
 */
export function carryForward(previous: readonly TriageBlock[], next: readonly TriageBlock[]): TriageBlock[] {
  const prior = new Map<string, PriorEntry>();
  previous.forEach((block, owner) => {
    for (const signature of block.signatures) {
      const key = priorKey(signature, block.substantial);
      const seen = prior.get(key);
      // An open block wins: the same content cleared in one place and open in
      // another has not been cleared.
      if (seen === undefined || (block.state === 'open' && seen.state !== 'open')) {
        prior.set(key, { state: block.state, rounds: block.rounds ?? [], owner });
      }
    }
  });
  return next.map((block) => carryOne(block, prior));
}

function priorKey(signature: string, substantial: boolean): string {
  return `${substantial ? 'sub' : 'triv'}:${signature}`;
}

/** `block` with whatever the previous capture earned it, or unchanged. */
function carryOne(block: TriageBlock, prior: ReadonlyMap<string, PriorEntry>): TriageBlock {
  if (block.signatures.length === 0) return block;
  let state: BlockState = 'resolved';
  const owners = new Set<number>();
  for (const signature of block.signatures) {
    const seen = prior.get(priorKey(signature, block.substantial));
    // New content: nothing about this thread carries, so it comes back as
    // triage rated it.
    if (seen === undefined) return block;
    if (seen.state === 'open') state = 'open';
    owners.add(seen.owner);
  }
  const first = prior.get(priorKey(block.signatures[0] ?? '', block.substantial));
  const rounds = owners.size === 1 && first !== undefined ? first.rounds : [];
  return { ...block, state, reopened: state === 'open' && !block.substantial, rounds };
}

export interface TriageCounts {
  total: number;
  open: number;
  substantial: number;
  /** Substantial threads already cleared: the "3 of 5 defended" numerator. */
  defended: number;
}

export function countBlocks(blocks: readonly TriageBlock[]): TriageCounts {
  const substantial = blocks.filter((block) => block.substantial);
  return {
    total: blocks.length,
    open: blocks.filter((block) => block.state === 'open').length,
    substantial: substantial.length,
    defended: substantial.filter((block) => block.state === 'resolved').length,
  };
}
