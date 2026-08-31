import type { BigSpec } from './bigstore.js';
import type { TriageBlock } from './triage.js';

/**
 * What each big-change turn is told and what shape its answer must take.
 *
 * Prompt text steers; it never enforces. The read-only intake turn is
 * read-only because of its tool list, and the build stays in the worktree
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
    `You are in a disposable git worktree at ${worktree}; it is yours to change freely.`,
    'Run whatever tests the project already has, and fix what you break.',
    'Do NOT commit and do NOT push — the change is reviewed as a working tree.',
    'Do not write outside this worktree.',
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
    'Revise the worktree accordingly. Keep the rest of the change intact, run the tests again,',
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

export function composeTriagePrompt(spec: BigSpec | null, rendered: string, truncated: boolean): string {
  const intent = spec === null ? '' : `\nWhat the change was meant to do:\n${spec.goal}\n`;
  const note = truncated
    ? '\nThe diff was too large to show in full; group what is here.\n'
    : '';
  return `${TRIAGE_INSTRUCTION}\n${intent}${note}\n${rendered}`;
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
