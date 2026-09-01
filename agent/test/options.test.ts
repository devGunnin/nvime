import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { INTAKE_SCHEMA, parseIntakeOutput } from '../src/bigprompts.js';
import {
  extractOptions,
  MAX_OPTIONS,
  OPTIONS_FENCE_LANG,
  OPTIONS_SCHEMA,
  parseOptionsBlock,
} from '../src/options.js';

const CHOICES = [{ label: 'a __version__ constant' }, { label: 'read it from pyproject.toml' }];

function block(count: number): unknown {
  return { options: Array.from({ length: count }, (_, i) => ({ label: `choice ${i + 1}` })) };
}

describe('parseOptionsBlock', () => {
  it('takes a well-formed block and defaults what the model left out', () => {
    const parsed = parseOptionsBlock({ prompt: ' where? ', options: CHOICES });
    assert.deepEqual(parsed, { prompt: 'where?', options: CHOICES, multi: false });
  });

  it('keeps a per-choice detail and drops an empty one', () => {
    const parsed = parseOptionsBlock({ options: [{ label: 'a', detail: ' why ' }, { label: 'b', detail: '  ' }] });
    assert.deepEqual(parsed?.options, [{ label: 'a', detail: 'why' }, { label: 'b' }]);
  });

  it('accepts a bare string as a label, which is what a terse model sends', () => {
    assert.deepEqual(parseOptionsBlock({ options: ['a', 'b'] })?.options, [{ label: 'a' }, { label: 'b' }]);
  });

  /** The model wrote this; every one of these is a payload it could produce. */
  it('refuses anything the editor could not render, rather than half of it', () => {
    for (const raw of [
      null,
      'choose',
      {},
      { options: 'a, b' },
      { options: [] },
      { options: [{ label: 'only' }] },
      { options: [{ label: 'a' }, { label: '  ' }] },
      { options: [{ label: 'a' }, 7] },
      block(MAX_OPTIONS + 1),
    ]) {
      assert.equal(parseOptionsBlock(raw), null, JSON.stringify(raw));
    }
    assert.ok(parseOptionsBlock(block(MAX_OPTIONS)) !== null, 'exactly the cap is still fine');
  });
});

describe('extractOptions', () => {
  const fence = (json: string): string => `Which one?\n\n\`\`\`${OPTIONS_FENCE_LANG}\n${json}\n\`\`\`\n`;

  it('lifts the block out and leaves the prose that asked the question', () => {
    const result = extractOptions(fence(JSON.stringify({ options: CHOICES })));
    assert.equal(result.text, 'Which one?');
    assert.deepEqual(result.options?.options, CHOICES);
  });

  it('leaves a reply with no fence exactly as it was', () => {
    const plain = 'no choice here, just prose';
    assert.deepEqual(extractOptions(plain), { text: plain, options: null });
  });

  /** A reply that demonstrates the format before using it offers the last one. */
  it('takes the last fence when a reply carries more than one', () => {
    const text = fence(JSON.stringify({ options: [{ label: 'x' }, { label: 'y' }] })) + fence(
      JSON.stringify({ options: CHOICES }),
    );
    assert.deepEqual(extractOptions(text).options?.options, CHOICES);
  });

  /** The panel already swallowed the fence as it streamed, so leaving it in
   *  the returned text would make a resumed session read differently. */
  it('still strips a malformed block, and offers no choice for it', () => {
    const result = extractOptions(fence('{not json'));
    assert.equal(result.text, 'Which one?');
    assert.equal(result.options, null);
  });

  it('offers no choice for a fence holding valid JSON that is not a block', () => {
    assert.equal(extractOptions(fence('{"options":[]}')).options, null);
  });

  it('leaves an ordinary code fence alone', () => {
    const text = 'here:\n```json\n{"options":[{"label":"a"},{"label":"b"}]}\n```\n';
    assert.deepEqual(extractOptions(text), { text, options: null });
  });

  /** The panel's own classifier (`markdown.lua`) treats a fence-marker line
   *  seen while already inside a fence as CLOSING it, not as opening a
   *  nested one — so a `nvime-options` fence quoted inside another fence is
   *  inert: never swallowed, never a live widget. The sidecar has to agree,
   *  or a reopened session reads differently from the live one, and repo
   *  content the model merely quoted becomes a pressable choice. */
  describe('a fence nested inside another fence', () => {
    it('is inert — text and options both come back exactly as sent', () => {
      const text = 'From README.md:\n```md\n```nvime-options\n{"options":[{"label":"a"},{"label":"b"}]}\n```\n```\n';
      assert.deepEqual(extractOptions(text), { text, options: null });
    });

    it('stays inert with a 4-backtick outer fence too', () => {
      const text =
        'quoting it:\n````md\n```nvime-options\n{"options":[{"label":"a"},{"label":"b"}]}\n```\n````\n';
      assert.deepEqual(extractOptions(text), { text, options: null });
    });
  });

  /** `markdown.lua`'s fence tracking is one open/closed flag: 4+ backticks,
   *  a tilde fence, and an unterminated fence all have to agree with what
   *  the panel actually swallowed live, not just the plain 3-backtick case. */
  describe('fence marker parity with the panel', () => {
    it('takes a 4-backtick fence the same as a 3-backtick one', () => {
      const result = extractOptions(`Which one?\n\n\`\`\`\`${OPTIONS_FENCE_LANG}\n${JSON.stringify({ options: CHOICES })}\n\`\`\`\`\n`);
      assert.equal(result.text, 'Which one?');
      assert.deepEqual(result.options?.options, CHOICES);
    });

    it('takes a tilde fence the same as a backtick one', () => {
      const result = extractOptions(`Which one?\n\n~~~${OPTIONS_FENCE_LANG}\n${JSON.stringify({ options: CHOICES })}\n~~~\n`);
      assert.equal(result.text, 'Which one?');
      assert.deepEqual(result.options?.options, CHOICES);
    });

    it('lets a tilde fence close a backtick-opened one, matching the panel', () => {
      const result = extractOptions(`Which one?\n\n\`\`\`${OPTIONS_FENCE_LANG}\n${JSON.stringify({ options: CHOICES })}\n~~~\n`);
      assert.equal(result.text, 'Which one?');
      assert.deepEqual(result.options?.options, CHOICES);
    });

    /** A cut-off reply: the panel swallows everything from the fence open
     *  onward with nothing left to render, and offers no choice for it. */
    it('drops everything from an unterminated fence onward, and offers no choice', () => {
      const text = `Which one?\n\n\`\`\`${OPTIONS_FENCE_LANG}\n${JSON.stringify({ options: CHOICES })}`;
      assert.deepEqual(extractOptions(text), { text: 'Which one?', options: null });
    });
  });
});

describe('the intake turn’s options', () => {
  it('offers the schema on the turn that asks the question', () => {
    const properties = INTAKE_SCHEMA.properties as Record<string, unknown>;
    assert.equal(properties.options, OPTIONS_SCHEMA);
    const required = INTAKE_SCHEMA.required as string[];
    assert.ok(!required.includes('options'), 'an open question offers none');
  });

  it('carries a well-formed block through to the caller', () => {
    const answer = parseIntakeOutput({ ready: false, message: 'which version?', options: { options: CHOICES } });
    assert.equal(answer?.message, 'which version?');
    assert.deepEqual(answer?.options?.options, CHOICES);
  });

  /** Free text has to keep working whatever the model does with the schema. */
  it('still answers as prose when the model ignored the options entirely', () => {
    const answer = parseIntakeOutput({ ready: false, message: 'which version?' });
    assert.equal(answer?.message, 'which version?');
    assert.equal(answer?.options, null);
  });

  it('does not crash on a malformed block, and offers no choice for it', () => {
    for (const options of [null, 'a or b', { options: [{ label: 'only' }] }, 42]) {
      const answer = parseIntakeOutput({ ready: false, message: 'which?', options });
      assert.equal(answer?.message, 'which?');
      assert.equal(answer?.options, null, JSON.stringify(options));
    }
  });

  /** A finished spec is not a question, so there is nothing left to pick. */
  it('offers no choice alongside a spec it is ready to build', () => {
    const answer = parseIntakeOutput({
      ready: true,
      message: 'here is the spec',
      options: { options: CHOICES },
      spec: { goal: 'add a flag', scope: [], approach: '', acceptance: [], outOfScope: [] },
    });
    assert.equal(answer?.ready, true);
    assert.equal(answer?.options, null);
  });
});
