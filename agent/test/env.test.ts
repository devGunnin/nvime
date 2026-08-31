import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  STRIPPED_ENV_VARS,
  resolveClaudeExecutable,
  strippedNames,
  subscriptionEnv,
} from '../src/env.js';

describe('subscriptionEnv', () => {
  it('removes every credential and provider override', () => {
    const source: Record<string, string | undefined> = { PATH: '/usr/bin', HOME: '/home/x' };
    for (const name of STRIPPED_ENV_VARS) source[name] = 'leaked';
    const env = subscriptionEnv(source);
    for (const name of STRIPPED_ENV_VARS) {
      assert.equal(env[name], undefined, `${name} must not reach the SDK subprocess`);
    }
  });

  it('keeps the rest of the environment intact', () => {
    const env = subscriptionEnv({ PATH: '/usr/bin', HOME: '/home/x', ANTHROPIC_API_KEY: 'k' });
    assert.equal(env.PATH, '/usr/bin');
    assert.equal(env.HOME, '/home/x');
  });

  it('does not mutate the caller environment', () => {
    const source = { ANTHROPIC_API_KEY: 'k' };
    subscriptionEnv(source);
    assert.equal(source.ANTHROPIC_API_KEY, 'k');
  });

  it('reports only variables that are actually set', () => {
    assert.deepEqual(strippedNames({ ANTHROPIC_API_KEY: 'k', ANTHROPIC_AUTH_TOKEN: '' }), [
      'ANTHROPIC_API_KEY',
    ]);
    assert.deepEqual(strippedNames({ PATH: '/usr/bin' }), []);
  });
});

describe('resolveClaudeExecutable', () => {
  const present = (paths: string[]) => (candidate: string) => paths.includes(candidate);

  it('returns the first PATH hit', () => {
    const found = resolveClaudeExecutable(
      { PATH: '/a:/b:/c' },
      present(['/b/claude', '/c/claude']),
    );
    assert.equal(found, '/b/claude');
  });

  it('returns null when nothing on PATH is executable', () => {
    assert.equal(resolveClaudeExecutable({ PATH: '/a:/b' }, present([])), null);
  });

  it('returns null when PATH is absent', () => {
    assert.equal(resolveClaudeExecutable({}, present(['/a/claude'])), null);
  });

  it('honours an explicit override, and fails loudly when it is wrong', () => {
    assert.equal(
      resolveClaudeExecutable({ NVIME_CLAUDE_PATH: '/opt/claude', PATH: '/a' }, present(['/opt/claude', '/a/claude'])),
      '/opt/claude',
    );
    assert.equal(
      resolveClaudeExecutable({ NVIME_CLAUDE_PATH: '/opt/claude', PATH: '/a' }, present(['/a/claude'])),
      null,
      'a bad override must not silently fall back to PATH',
    );
  });
});
