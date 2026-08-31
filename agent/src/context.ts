import { relative } from 'node:path';
import { ProtocolError } from './protocol.js';

/**
 * Deliberate context the user attached to a prompt (`@file`, `@dir`, a visual
 * selection). The plugin reads the bytes; the sidecar only shapes them into
 * the prompt, so context is auditable on one side and rendered on the other.
 */
export type ContextBlock =
  | { type: 'file'; path: string; text: string }
  | { type: 'dir'; path: string; entries: string[] }
  | { type: 'selection'; path: string; startLine: number; endLine: number; text: string };

/** Total attached context accepted per send; the plugin caps well below this. */
export const MAX_CONTEXT_BYTES = 512 * 1024;

export function parseContextBlocks(raw: unknown[]): ContextBlock[] {
  const blocks = raw.map(parseBlock);
  const bytes = blocks.reduce((sum, block) => sum + blockBytes(block), 0);
  if (bytes > MAX_CONTEXT_BYTES) {
    throw new ProtocolError(
      'bad_request',
      `attached context is ${bytes} bytes, over the ${MAX_CONTEXT_BYTES} byte limit`,
    );
  }
  return blocks;
}

function parseBlock(raw: unknown, index: number): ContextBlock {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new ProtocolError('bad_request', `context[${index}] must be an object`);
  }
  const block = raw as Record<string, unknown>;
  const path = str(block.path, `context[${index}].path`);
  switch (block.type) {
    case 'file':
      return { type: 'file', path, text: str(block.text, `context[${index}].text`, true) };
    case 'dir':
      return { type: 'dir', path, entries: strArray(block.entries, `context[${index}].entries`) };
    case 'selection':
      return {
        type: 'selection',
        path,
        startLine: int(block.startLine, `context[${index}].startLine`),
        endLine: int(block.endLine, `context[${index}].endLine`),
        text: str(block.text, `context[${index}].text`, true),
      };
    default:
      throw new ProtocolError('bad_request', `context[${index}].type is not a known block type`);
  }
}

function str(value: unknown, label: string, allowEmpty = false): string {
  if (typeof value !== 'string' || (!allowEmpty && value === '')) {
    throw new ProtocolError('bad_request', `${label} must be a string`);
  }
  return value;
}

function strArray(value: unknown, label: string): string[] {
  if (!Array.isArray(value)) throw new ProtocolError('bad_request', `${label} must be an array`);
  return value.map((entry, i) => str(entry, `${label}[${i}]`));
}

function int(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    throw new ProtocolError('bad_request', `${label} must be a positive integer`);
  }
  return value;
}

function blockBytes(block: ContextBlock): number {
  if (block.type === 'dir') return block.entries.reduce((n, e) => n + e.length, 0);
  return Buffer.byteLength(block.text, 'utf8');
}

/**
 * Renders prompt + attached context as one string. The SDK accepts a string
 * prompt; fenced, path-labelled sections keep the attachments unambiguous
 * without needing the streaming-input message form.
 */
export function composePrompt(prompt: string, blocks: readonly ContextBlock[], cwd: string): string {
  if (blocks.length === 0) return prompt;
  const sections = blocks.map((block) => renderBlock(block, cwd));
  return `${sections.join('\n\n')}\n\n${prompt}`;
}

/** One leading `<context …>` section, exactly as `renderBlock` writes it. */
const CONTEXT_SECTION = /^<context [^>\n]*>\n[\s\S]*?\n<\/context>\n\n/;

/**
 * The bare prompt behind a stored transcript message. A resumed turn must not
 * replay a 150 KB attachment into the panel as something the user typed.
 * Anchored and non-greedy, so file text that itself contains `</context>` can
 * cost a little extra trimming but never eats the prompt.
 */
export function stripContextSections(text: string): string {
  let rest = text;
  while (CONTEXT_SECTION.test(rest)) rest = rest.replace(CONTEXT_SECTION, '');
  return rest;
}

function renderBlock(block: ContextBlock, cwd: string): string {
  const shown = relative(cwd, block.path) || block.path;
  switch (block.type) {
    case 'file':
      return `<context file="${shown}">\n${block.text}\n</context>`;
    case 'dir':
      return `<context dir="${shown}">\n${block.entries.join('\n')}\n</context>`;
    case 'selection':
      return `<context file="${shown}" lines="${block.startLine}-${block.endLine}">\n${block.text}\n</context>`;
  }
}
