import type { BigSpec } from './bigstore.js';
import type { GateRound } from './gate.js';
import type { TriageBlock } from './triage.js';

/**
 * What each big-change turn is told and what shape its answer must take.
 *
 * Prompt text steers; it never enforces. The read-only intake turn is
 * read-only because of its tool list, and the build's writes stay in its clone
 * because of `classifyBuildTool` — not because either was asked nicely.
 */

/** Intake returns one object per turn: a question, or the spec played back. */
export const INTAKE_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['ready', 'message'],
  properties: {
    ready: {
      type: 'boolean',
      description: 'true only when the spec is concrete enough to build from with no further questions',
    },
    message: {
      type: 'string',
      description: 'the next question when not ready; otherwise a short plain-language playback of the spec',
    },
    spec: {
      type: 'object',
      additionalProperties: false,
      required: ['goal', 'scope', 'approach', 'acceptance', 'outOfScope'],
      properties: {
        goal: { type: 'string', description: 'one sentence: what will be true afterwards' },
        scope: { type: 'array', items: { type: 'string' }, description: 'the files or areas that change' },
        approach: { type: 'string', description: 'how it will be built' },
        acceptance: { type: 'array', items: { type: 'string' }, description: 'checks that prove it works' },
        outOfScope: { type: 'array', items: { type: 'string' }, description: 'what will deliberately not change' },
      },
    },
  },
};

const INTAKE_INSTRUCTION = [
  'You are scoping a change to this repository before any code is written.',
  'Read whatever you need to; you cannot modify anything.',
  'Ask about exactly what is still ambiguous — one focused question at a time, and none you could',
  'answer yourself by reading the code. When nothing material is left open, set ready to true and',
  'fill in the spec: goal, scope, approach, acceptance criteria, and what is explicitly out of scope.',
  'Never set ready true with a spec you had to guess at.',
].join(' ');

/** The first intake turn. Later turns are plain replies on the same session. */
export function composeIntakeOpening(title: string, request: string): string {
  return `${INTAKE_INSTRUCTION}\n\nThe change is called "${title}".\n\nThe request:\n${request}`;
}

/**
 * The build turn. States the sandbox and the no-commit rule in words because
 * the model needs to know them; neither is enforced by this text.
 */
export function composeBuildPrompt(spec: BigSpec, worktree: string): string {
  return [
    'Implement the following change completely, in this working directory.',
    `You are in a disposable clone of the repository at ${worktree}; it is yours to change freely.`,
    'Run whatever tests the project already has, and fix what you break.',
    'Do NOT commit and do NOT push — the change is reviewed as a working tree.',
    'Do not write outside this directory.',
    '',
    renderSpec(spec),
    '',
    'When you are done, say in a few sentences what you built and what you verified.',
  ].join('\n');
}

/** A reviewer's request for changes, on the build session that produced them. */
export function composeRevisionPrompt(block: TriageBlock, comment: string): string {
  const where = block.files.length === 0 ? '' : ` (${block.files.join(', ')})`;
  return [
    `The reviewer requested changes to "${block.title}"${where}.`,
    '',
    'Their comment:',
    comment,
    '',
    'Revise this working directory accordingly. Keep the rest of the change intact, run the tests again,',
    'and still do not commit. Then say in one or two sentences what you changed.',
  ].join('\n');
}

const TRIAGE_INSTRUCTION = [
  'Group the hunks below into review threads for a human reader.',
  'Each hunk id must appear in exactly one group.',
  'Mark a group substantial when the reader has to understand it to trust the change — logic,',
  'behavior, contracts, error handling, data shape. Mark it not substantial only for mechanical',
  'churn: imports, comments, formatting, version bumps, mechanical renames.',
  'When in doubt, substantial. Do not read files; group only what is shown.',
].join(' ');

export function composeTriagePrompt(
  spec: BigSpec | null,
  rendered: string,
  truncated: boolean,
  shownHunks: number,
  totalHunks: number,
): string {
  const intent = spec === null ? '' : `\nWhat the change was meant to do:\n${spec.goal}\n`;
  const note = truncated
    ? `\nOnly ${shownHunks} of ${totalHunks} hunks fit the size limit and are shown below; the rest were not ` +
      'shown at all. Group only what is here.\n'
    : '';
  return `${TRIAGE_INSTRUCTION}\n${intent}${note}\n${rendered}`;
}

/**
 * The rubric. It is long because every line of it closes a way of passing
 * without understanding — the failure mode this whole feature exists to stop.
 *
 * It steers and does not enforce: the SCORE is enforced by the threshold in
 * `gate.ts`, and an unusable answer leaves the thread open no matter what this
 * text asked for.
 */
const GRADE_INSTRUCTION = [
  'You are grading how well a reader understands a change they did not write. They are about to merge it',
  'into their own repository, and your grade is the only thing standing between them and code they cannot',
  'maintain. Be exacting and be fair.',
  '',
  'Grade UNDERSTANDING, not eloquence. A blunt, plain, ungrammatical answer that names what the change does',
  'and why beats a polished one that does not. Never reward length, vocabulary, confidence, hedging, or',
  'politeness toward you.',
  '',
  'What scores low:',
  '  - restating the diff line by line ("it adds a lock and sets a flag") without saying what that ACHIEVES;',
  '  - an answer generic enough to fit any change of this shape ("it refactors for clarity", "it fixes a bug",',
  '    "it improves error handling") — if it would still be true of a different diff, it is not understanding;',
  '  - naming the mechanism but not the failure it prevents or the behavior it changes;',
  '  - any claim about this change that is factually wrong. Cap such an answer below the pass mark.',
  'What scores high:',
  '  - specifics that could only come from reading THIS change: the actual condition, the actual case it',
  '    handles, the actual tradeoff taken, what would break without it;',
  '  - correctly naming a consequence the diff implies but does not state.',
  '',
  'If a follow-up question was asked, an answer that does not address it cannot pass, however good otherwise.',
  'For an answer that falls short, write a hint that points at what they have not accounted for — Socratic,',
  'never the answer itself — and one follow-up question that would settle whether they understand. For an',
  'answer that passes, leave hint and followup empty.',
  'You may read the repository to check a claim. Return exactly one entry per thread id below, copied exactly.',
].join('\n');

export interface GradeItem {
  threadId: string;
  title: string;
  rationale: string;
  /** The thread's hunks, exactly as the reader saw them. */
  diff: string;
  /** Earlier rounds on this thread, oldest first. */
  history: readonly GateRound[];
  /** The question this answer had to address, or '' for a first answer. */
  followup: string;
  answer: string;
}

/**
 * One grading turn for a whole round: every thread answered, graded together.
 *
 * `resumed` says the grader's own SDK session is being continued. The rubric
 * and the pass mark are sent on EVERY round regardless — they are ~1.5KB, and a
 * resume that silently comes back with a pruned context (an expired SDK
 * session resuming into a fresh one, say) must never grade without them: a
 * grade given blind can still clear a thread. Only the per-thread diff and
 * verdict history are trimmed on a thread the grader has already seen, which
 * is what makes resuming worth doing — that is the bulk of what a round would
 * otherwise re-send. A thread being graded for the FIRST time still gets the
 * full rendering, resumed or not — that context is new whatever round it
 * arrives in.
 */
export function composeGradePrompt(
  spec: BigSpec | null,
  threshold: number,
  items: readonly GradeItem[],
  resumed = false,
): string {
  if (items.length === 0) throw new Error('a grading turn needs at least one answered thread');
  const intent = resumed || spec === null ? '' : `\nWhat the change as a whole was meant to do:\n${spec.goal}\n`;
  const bar =
    `\nThe pass mark for this session is ${threshold} out of 100. Grade against it honestly: do not` +
    ' round an answer up to spare them another round, and do not hold back a passing answer.\n';
  const resumeNote = resumed ? `\n${RESUME_NOTE}\n` : '';
  return `${GRADE_INSTRUCTION}\n${intent}${bar}${resumeNote}\n${items.map((item) => renderGradeItem(item, resumed)).join('\n')}`;
}

/** Explains the abbreviated rendering below — never a replacement for the
 *  rubric or the pass mark, which stay in every round. */
const RESUME_NOTE =
  'This is a later round on some of the same threads. For a thread you have already graded, the change and ' +
  'your earlier verdict are already in this conversation and are not repeated below — only what is new is.';

/**
 * A thread as the grader is shown it. On a resumed session a thread it has
 * already graded is named rather than re-rendered: it has the hunks and its own
 * verdicts in context, and repeating them is what makes the round grow.
 */
function renderGradeItem(item: GradeItem, resumed: boolean): string {
  const known = resumed && item.history.length > 0;
  const parts = [`=== thread ${item.threadId}: ${item.title} ===`];
  if (!known) {
    if (item.rationale !== '') parts.push(`why it was grouped this way: ${item.rationale}`);
    parts.push('the change under review:', item.diff);
    for (const round of item.history) {
      if (round.result === null) continue;
      parts.push(`earlier answer: ${round.answer}`);
      parts.push(`you scored it ${round.result.grade} and said: ${round.result.verdict}`);
    }
  }
  if (item.followup !== '') parts.push(`the follow-up they had to address: ${item.followup}`);
  parts.push(`their answer now:\n${item.answer}`);
  return parts.join('\n') + '\n';
}

/**
 * The build agent's rebase turn. The sidecar already moved what it could
 * deterministically; this is for the part only a reader of the code can do.
 */
export function composeRebasePrompt(conflicted: boolean, baseBranch: string): string {
  const head = conflicted
    ? [
        `A rebase of this working directory onto the updated ${baseBranch} is IN PROGRESS and has stopped on`,
        'conflicts. Resolve every conflict in a way that keeps both the change you built and whatever the base',
        'branch introduced, then finish the rebase (`git rebase --continue`, staging as needed).',
      ]
    : [
        `This working directory has been rebased onto the updated ${baseBranch}. Nothing conflicted, but the`,
        'code around your change has moved.',
      ];
  return [
    ...head,
    '',
    'Then re-run whatever tests the project has and fix anything the new base broke.',
    'Do not push, and do not add anything the change did not already need.',
    'When you are done, say in a few sentences what conflicted and what you had to change.',
  ].join('\n');
}

const EXPLAIN_INSTRUCTION = [
  'Explain the change below in plain language, for a reader who has already cleared it and wants the plain',
  'reading spelled out. What it does, why, and what a reader should notice — two or three short paragraphs,',
  'no headers, and do not restate the diff line by line.',
].join(' ');

/** The post-clear `e`: one thread's hunks, explained. Read-only, and never
 *  offered while a substantial thread's own defense is still open — see
 *  `requireExplainable` in `big.ts`, which is what actually enforces that. */
export function composeExplainPrompt(block: TriageBlock, diff: string): string {
  const why = block.rationale === '' ? '' : `\nWhy it was grouped this way: ${block.rationale}\n`;
  return `${EXPLAIN_INSTRUCTION}\n\n=== ${block.title} ===${why}\n${diff}`;
}

function renderSpec(spec: BigSpec): string {
  const list = (label: string, items: readonly string[]): string =>
    items.length === 0 ? '' : `${label}:\n${items.map((item) => `  - ${item}`).join('\n')}\n`;
  return [
    `Goal: ${spec.goal}`,
    list('Scope', spec.scope),
    `Approach: ${spec.approach}`,
    list('Acceptance criteria', spec.acceptance),
    list('Out of scope', spec.outOfScope),
  ]
    .filter((part) => part !== '')
    .join('\n');
}

export interface IntakeAnswer {
  ready: boolean;
  message: string;
  spec: BigSpec | null;
}

/**
 * The intake turn's structured answer. Returns null when the turn produced
 * nothing usable, so the caller can fall back to its prose rather than invent
 * a spec — a fabricated spec is one the user would approve without noticing.
 */
export function parseIntakeOutput(raw: unknown): IntakeAnswer | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const answer = raw as Record<string, unknown>;
  const message = typeof answer.message === 'string' ? answer.message.trim() : '';
  const spec = parseSpec(answer.spec);
  if (message === '' && spec === null) return null;
  // Ready without a spec is a contradiction; the answer is treated as a question.
  return { ready: answer.ready === true && spec !== null, message, spec };
}

function parseSpec(raw: unknown): BigSpec | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const spec = raw as Record<string, unknown>;
  const goal = typeof spec.goal === 'string' ? spec.goal.trim() : '';
  if (goal === '') return null;
  return {
    goal,
    scope: strings(spec.scope),
    approach: typeof spec.approach === 'string' ? spec.approach.trim() : '',
    acceptance: strings(spec.acceptance),
    outOfScope: strings(spec.outOfScope),
  };
}

function strings(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter((item): item is string => typeof item === 'string' && item.trim() !== '').map((s) => s.trim());
}
