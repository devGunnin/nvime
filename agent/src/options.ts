/**
 * A choice the model offers the reader, in place of a question they have to
 * answer in prose.
 *
 * Two carriers, one shape. Intake already returns structured output, so its
 * schema simply grows an `options` property. Chat streams free text and has no
 * schema to grow, so the model opts in by ending its reply with a fenced
 * `nvime-options` block; the plugin's panel swallows that fence as it streams
 * and this module lifts the block out of the finished text.
 *
 * Nothing here trusts the model: an unusable block is no block, and the prose
 * question it came with is shown either way.
 */

export interface OptionChoice {
  label: string;
  detail?: string;
}

export interface OptionsBlock {
  prompt?: string;
  options: OptionChoice[];
  multi: boolean;
}

/** Mirrors `M.MAX_OPTIONS` in `lua/nvime/options.lua`; both refuse past it. */
export const MAX_OPTIONS = 12;

/** The fence language chat uses to opt in. The panel knows this string too. */
export const OPTIONS_FENCE_LANG = 'nvime-options';

/** The `options` property of a structured turn, and the chat fence's payload. */
export const OPTIONS_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['options'],
  description:
    'present only when the question is a pick between discrete alternatives; omit it entirely for an open question',
  properties: {
    prompt: { type: 'string', description: 'one short line naming what is being chosen' },
    options: {
      type: 'array',
      minItems: 2,
      maxItems: MAX_OPTIONS,
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['label'],
        properties: {
          label: { type: 'string', description: 'the alternative itself, in a few words' },
          detail: { type: 'string', description: 'one line on what picking it means' },
        },
      },
    },
    multi: { type: 'boolean', description: 'true when more than one may be picked at once' },
  },
};

const OPTIONS_RULE = [
  'When your question is a pick between discrete alternatives, offer them as options rather than prose:',
  'two or more short labels, each with one line saying what picking it means. Set multi when several can',
  'be picked at once. Ask an open question as plain prose and offer no options — options are for a choice,',
  'not for every question. The reader can always answer in their own words instead.',
].join(' ');

/** The intake turn's rule, for a schema that already carries `options`. */
export const INTAKE_OPTIONS_RULE = OPTIONS_RULE;

/** The chat turn's rule, which has to name the carrier as well. */
export const CHAT_OPTIONS_RULE = [
  OPTIONS_RULE,
  `To offer them, end your reply with a fenced \`${OPTIONS_FENCE_LANG}\` code block holding`,
  '{"prompt": "...", "options": [{"label": "...", "detail": "..."}], "multi": false}.',
  'The editor renders it as a numbered list the reader picks from; the block itself is never shown, so',
  'the prose above it must still read as a complete question.',
].join(' ');

function trimmed(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function parseChoice(raw: unknown): OptionChoice | null {
  const source = typeof raw === 'string' ? { label: raw } : raw;
  if (typeof source !== 'object' || source === null) return null;
  const entry = source as Record<string, unknown>;
  const label = trimmed(entry.label);
  if (label === '') return null;
  const detail = trimmed(entry.detail);
  return detail === '' ? { label } : { label, detail };
}

/**
 * Validates a block the model produced. Returns null for anything unusable —
 * a missing list, an entry with no label, fewer than two choices, or more than
 * a reader can take in — so the caller keeps the prose and offers no choice.
 */
export function parseOptionsBlock(raw: unknown): OptionsBlock | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const block = raw as Record<string, unknown>;
  if (!Array.isArray(block.options)) return null;
  const options: OptionChoice[] = [];
  for (const entry of block.options) {
    const choice = parseChoice(entry);
    if (choice === null) return null;
    options.push(choice);
  }
  if (options.length < 2 || options.length > MAX_OPTIONS) return null;
  const prompt = trimmed(block.prompt);
  return {
    ...(prompt === '' ? {} : { prompt }),
    options,
    multi: block.multi === true,
  };
}

/** Every `nvime-options` fence in a reply, with the JSON each one holds. */
const OPTIONS_FENCE = new RegExp('^[ \\t]*```' + OPTIONS_FENCE_LANG + '[ \\t]*\\n([\\s\\S]*?)\\n?^[ \\t]*```[ \\t]*$', 'gm');

/**
 * Lifts the options block out of a finished chat reply.
 *
 * The fence is always removed from the returned text, parseable or not: the
 * panel already swallowed it as it streamed, so leaving it in the stored
 * transcript would make a resumed session read differently from the live one.
 * The LAST fence wins — a reply that shows the format before using it should
 * be read as offering the block it ended with.
 */
export function extractOptions(text: string): { text: string; options: OptionsBlock | null } {
  OPTIONS_FENCE.lastIndex = 0;
  let payload: string | null = null;
  const stripped = text.replace(OPTIONS_FENCE, (_match, body: string) => {
    payload = body;
    return '';
  });
  if (payload === null) return { text, options: null };
  let raw: unknown;
  try {
    raw = JSON.parse(payload);
  } catch {
    // A malformed block is not an error the reader can act on: the prose above
    // it still asks the question, and that is what they answer.
    return { text: stripped.trimEnd(), options: null };
  }
  return { text: stripped.trimEnd(), options: parseOptionsBlock(raw) };
}
