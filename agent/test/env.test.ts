import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  GATE_ENV_VARS,
  STRIPPED_ENV_VARS,
  resolveClaudeExecutable,
  strippedNames,
  stripGateEnv,
  subscriptionEnv,
} from '../src/env.js';

/**
 * Named independently of `STRIPPED_ENV_VARS` on purpose. Asserting the export
 * against itself passes for any list, including a wrong one — which is how the
 * list came to name a variable the SDK never reads while missing four it does.
 */
const MUST_NOT_REACH_THE_CLI = {
  ANTHROPIC_API_KEY: 'sk-ant-leak',
  ANTHROPIC_AUTH_TOKEN: 'tok-leak',
  CLAUDE_CODE_OAUTH_TOKEN: 'oauth-leak',
  AWS_BEARER_TOKEN_BEDROCK: 'bedrock-leak',
  ANTHROPIC_BASE_URL: 'https://gateway.corp/',
  ANTHROPIC_CUSTOM_HEADERS: 'Authorization: Bearer leak',
  ANTHROPIC_BEDROCK_BASE_URL: 'https://bedrock.corp/',
  ANTHROPIC_VERTEX_BASE_URL: 'https://vertex.corp/',
  CLAUDE_CODE_USE_BEDROCK: '1',
  CLAUDE_CODE_USE_VERTEX: '1',
};

describe('subscriptionEnv', () => {
  it('removes the credentials and endpoint overrides by name', () => {
    const env = subscriptionEnv({ PATH: '/usr/bin', HOME: '/home/x', ...MUST_NOT_REACH_THE_CLI });
    for (const name of Object.keys(MUST_NOT_REACH_THE_CLI)) {
      assert.equal(env[name], undefined, `${name} must not reach the SDK subprocess`);
    }
    assert.equal(env.PATH, '/usr/bin', 'the environment is otherwise complete');
  });

  it('strips every name it advertises', () => {
    const source: Record<string, string | undefined> = { PATH: '/usr/bin' };
    for (const name of STRIPPED_ENV_VARS) source[name] = 'leaked';
    const env = subscriptionEnv(source);
    for (const name of STRIPPED_ENV_VARS) assert.equal(env[name], undefined);
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

describe('stripGateEnv', () => {
  it('removes every gate-only override by name', () => {
    const source: Record<string, string | undefined> = { PATH: '/usr/bin' };
    for (const name of GATE_ENV_VARS) source[name] = 'leaked';
    const env = stripGateEnv(source);
    for (const name of GATE_ENV_VARS) assert.equal(env[name], undefined, `${name} must not reach a gate turn`);
  });

  it('keeps the rest of the environment intact', () => {
    const env = stripGateEnv({ PATH: '/usr/bin', HOME: '/home/x', CLAUDE_CODE_EFFORT_LEVEL: 'low' });
    assert.equal(env.PATH, '/usr/bin');
    assert.equal(env.HOME, '/home/x');
  });

  it('does not mutate the caller environment', () => {
    const source = { CLAUDE_CODE_EFFORT_LEVEL: 'low' };
    stripGateEnv(source);
    assert.equal(source.CLAUDE_CODE_EFFORT_LEVEL, 'low');
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
