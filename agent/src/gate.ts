/**
 * The comprehension gate: what a defended thread records, how a grader's
 * answer is read, and what score clears a thread at each difficulty.
 *
 * Nothing here talks to the SDK or to disk. The grading TURN lives in
 * `big.ts`; this module is the part that has to be right, so it is pure and
 * tested on values.
 *
 * Imports nothing from `bigstore`/`triage` on purpose — both import this.
 */

export type Difficulty = 'vibe' | 'easy' | 'medium' | 'extreme';

export const DIFFICULTIES: readonly Difficulty[] = ['vibe', 'easy', 'medium', 'extreme'];

/**
 * The score a thread must reach to clear, per difficulty. `vibe` is null: no
 * gate at all, which is a different thing from a threshold of zero — a zero
 * would still make the reader type an answer.
 */
const THRESHOLDS: Readonly<Record<Difficulty, number | null>> = {
  vibe: null,
  easy: 40,
  medium: 70,
  extreme: 90,
};

export const DEFAULT_DIFFICULTY: Difficulty = 'medium';

export function isDifficulty(value: unknown): value is Difficulty {
  return typeof value === 'string' && (DIFFICULTIES as readonly string[]).includes(value);
}

/** The passing score, or null when this difficulty runs no gate. */
export function thresholdFor(difficulty: Difficulty): number | null {
  return THRESHOLDS[difficulty];
}

/** Whether substantial threads must be defended before the merge unlocks. */
export function gateArmed(difficulty: Difficulty): boolean {
  return thresholdFor(difficulty) !== null;
}

/** One grader verdict on one answer. */
export interface GateGrade {
  /** 0-100, integer. Understanding, not eloquence. */
  grade: number;
  /** One line: what the answer got, and what it missed. */
  verdict: string;
  /** A Socratic nudge, when the answer fell short. Empty when it cleared. */
  hint: string;
  /** The question the next answer must address. Empty when it cleared. */
  followup: string;
}

/**
 * One round of the loop: what the reader wrote, and what came back.
 *
 * An ungraded round is a case of its own rather than a grade of zero: the
 * grading turn failed or answered unusably, the thread stays open, and the
 * reason is kept on the record so the reader is told why instead of being
 * shown a score nobody gave them.
 */
export type GateRound =
  | { at: number; answer: string; result: GateGrade }
  | { at: number; answer: string; result: null; ungraded: string };

/** What the grader is asked to return. Enforced by the SDK, then re-checked. */
export const GRADE_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['grades'],
  properties: {
    grades: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['threadId', 'grade', 'verdict', 'hint', 'followup'],
        properties: {
          threadId: { type: 'string', description: 'the thread id this grade is for, copied exactly' },
          grade: { type: 'integer', description: '0-100: how well the answer shows understanding of THIS change' },
          verdict: { type: 'string', description: 'one line: what the answer got right and what it missed' },
          hint: {
            type: 'string',
            description: 'a Socratic nudge toward what was missed, never the answer itself; empty when it passed',
          },
          followup: {
            type: 'string',
            description: 'the question the next answer must address; empty when it passed',
          },
        },
      },
    },
  },
};

/**
 * The grader's answer, keyed by thread. Entries that are not a usable grade
 * are DROPPED rather than coerced — a thread with no entry here stays open
 * with an honest notice, which is the only safe reading of a garbage grade.
 *
 * Returns null when the payload is not a grade list at all, so the caller can
 * tell "the turn answered nothing" from "the turn skipped one thread".
 */
export function parseGradeOutput(raw: unknown): Map<string, GateGrade> | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const grades = (raw as { grades?: unknown }).grades;
  if (!Array.isArray(grades)) return null;
  const out = new Map<string, GateGrade>();
  for (const entry of grades) {
    const parsed = parseOneGrade(entry);
    if (parsed === null) continue;
    // First verdict wins: a grader that answered twice for one thread has
    // contradicted itself, and the later entry is no more trustworthy.
    if (!out.has(parsed.threadId)) out.set(parsed.threadId, parsed.grade);
  }
  return out;
}

function parseOneGrade(entry: unknown): { threadId: string; grade: GateGrade } | null {
  if (typeof entry !== 'object' || entry === null) return null;
  const record = entry as Record<string, unknown>;
  const threadId = record.threadId;
  if (typeof threadId !== 'string' || threadId === '') return null;
  const score = record.grade;
  if (typeof score !== 'number' || !Number.isFinite(score) || score < 0 || score > 100) return null;
  return {
    threadId,
    grade: {
      grade: Math.round(score),
      verdict: text(record.verdict),
      hint: text(record.hint),
      followup: text(record.followup),
    },
  };
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/** Whether a grade clears the thread. A null threshold never gets here. */
export function clears(grade: GateGrade, threshold: number): boolean {
  return grade.grade >= threshold;
}

/** The question the next answer must address, or null when none is pending. */
export function pendingFollowup(rounds: readonly GateRound[]): string | null {
  const last = rounds[rounds.length - 1];
  if (last === undefined || last.result === null) return null;
  return last.result.followup === '' ? null : last.result.followup;
}

/** The most recent score for a thread, or null when it has never been graded. */
export function lastGrade(rounds: readonly GateRound[]): number | null {
  for (let index = rounds.length - 1; index >= 0; index -= 1) {
    const result = rounds[index]?.result;
    if (result != null) return result.grade;
  }
  return null;
}
