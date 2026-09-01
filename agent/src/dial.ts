import type { EffortLevel, Options } from '@anthropic-ai/claude-agent-sdk';
import { ProtocolError } from './protocol.js';

/**
 * Reasoning-effort levels the plugin exposes. The SDK also accepts `'xhigh'`
 * and `'max'`, but nvime's config and `:Nvime model` picker only ever offer
 * these three, so a wider value here would be a protocol bug, not user input.
 */
export const EFFORT_LEVELS = ['low', 'medium', 'high'] as const;

/** Model + reasoning effort for one agent turn. Undefined uses the CLI default. */
export interface Dial {
  model?: string | undefined;
  effort?: EffortLevel | undefined;
}

/** Reads `params.model`/`params.effort`, the per-request shape every lane sends. */
export function parseDial(params: Record<string, unknown>): Dial {
  return { model: optionalModel(params), effort: optionalEffort(params) };
}

function optionalModel(params: Record<string, unknown>): string | undefined {
  const value = params.model;
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string' || value === '') {
    throw new ProtocolError('bad_request', 'params.model must be a non-empty string');
  }
  return value;
}

function optionalEffort(params: Record<string, unknown>): EffortLevel | undefined {
  const value = params.effort;
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string' || !(EFFORT_LEVELS as readonly string[]).includes(value)) {
    throw new ProtocolError('bad_request', `params.effort must be one of: ${EFFORT_LEVELS.join(', ')}`);
  }
  return value as EffortLevel;
}

/** Spread into SDK `Options` — omits whichever half of the dial is unset. */
export function dialOptions(dial: Dial): Pick<Options, 'model' | 'effort'> {
  return {
    ...(dial.model === undefined ? {} : { model: dial.model }),
    ...(dial.effort === undefined ? {} : { effort: dial.effort }),
  };
}
