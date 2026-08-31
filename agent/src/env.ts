import { accessSync, constants } from 'node:fs';
import { delimiter, join } from 'node:path';

/**
 * Subscription auth is a hard product constraint: the SDK must drive the
 * locally installed `claude` and its existing login. These variables would
 * route the CLI to an API key or a cloud provider instead, so they are removed
 * from the environment the SDK hands the subprocess.
 */
export const STRIPPED_ENV_VARS = [
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_BEARER_TOKEN',
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_VERTEX',
] as const;

export type Env = Record<string, string | undefined>;

/**
 * Copy of `source` with every credential-bearing variable removed. The SDK's
 * `env` option REPLACES the subprocess environment, so the copy must stay
 * complete otherwise (PATH, HOME, XDG_*).
 */
export function subscriptionEnv(source: Env): Env {
  const env: Env = { ...source };
  for (const name of STRIPPED_ENV_VARS) delete env[name];
  return env;
}

/** Names an env var the plugin should warn about, or null when clean. */
export function strippedNames(source: Env): string[] {
  return STRIPPED_ENV_VARS.filter((name) => source[name] !== undefined && source[name] !== '');
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    // Not executable or not present: this candidate simply loses.
    return false;
  }
}

/**
 * First executable named `claude` on PATH, or null. Resolved here rather than
 * left to the SDK so that a missing CLI is a structured error frame instead of
 * a spawn failure deep inside a query.
 */
export function resolveClaudeExecutable(
  env: Env,
  exists: (path: string) => boolean = isExecutable,
): string | null {
  const override = env.NVIME_CLAUDE_PATH;
  if (override !== undefined && override !== '') {
    return exists(override) ? override : null;
  }
  const path = env.PATH;
  if (path === undefined || path === '') return null;
  for (const dir of path.split(delimiter)) {
    if (dir === '') continue;
    const candidate = join(dir, 'claude');
    if (exists(candidate)) return candidate;
  }
  return null;
}
