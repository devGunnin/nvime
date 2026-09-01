import { accessSync, constants } from 'node:fs';
import { delimiter, join } from 'node:path';

/**
 * Subscription auth is a hard product constraint: the SDK must drive the
 * locally installed `claude` and its existing login. Every name below is read
 * by the shipped SDK bundle to supply a credential, redirect the endpoint, or
 * select another provider — `test/env-sdk-contract.test.ts` re-derives the set
 * from `node_modules` so a future SDK cannot add one unnoticed.
 */
export const STRIPPED_ENV_VARS = [
  // Credentials, including the ones handed over as an inherited descriptor.
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_AWS_API_KEY',
  'ANTHROPIC_FOUNDRY_API_KEY',
  'ANTHROPIC_FOUNDRY_AUTH_TOKEN',
  'ANTHROPIC_IDENTITY_TOKEN',
  'ANTHROPIC_IDENTITY_TOKEN_FILE',
  'AWS_BEARER_TOKEN_BEDROCK',
  'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR',
  'CLAUDE_CODE_CLIENT_CERT',
  'CLAUDE_CODE_CLIENT_KEY',
  'CLAUDE_CODE_CLIENT_KEY_PASSPHRASE',
  'CLAUDE_CODE_CERT_STORE',
  'CLAUDE_CODE_HFI_BEARER_TOKEN',
  'CLAUDE_CODE_OAUTH_REFRESH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
  'CLAUDE_CODE_SESSION_ACCESS_TOKEN',
  // Endpoint redirection: these reroute the prompt and the OAuth credential.
  'ANTHROPIC_AWS_BASE_URL',
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_BEDROCK_BASE_URL',
  'ANTHROPIC_BEDROCK_MANTLE_BASE_URL',
  'ANTHROPIC_CUSTOM_HEADERS',
  'ANTHROPIC_FOUNDRY_BASE_URL',
  'ANTHROPIC_GOOGLE_CLOUD_BASE_URL',
  'ANTHROPIC_UNIX_SOCKET',
  'ANTHROPIC_VERTEX_BASE_URL',
  'CLAUDE_CODE_API_BASE_URL',
  'CLAUDE_CODE_CUSTOM_OAUTH_URL',
  '_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL',
  // Profile/scope selection: a stored profile carries its own credential and
  // can carry its own base_url, so selecting one is equivalent to the two
  // categories above.
  'ANTHROPIC_PROFILE',
  'ANTHROPIC_CONFIG_DIR',
  'ANTHROPIC_SCOPE',
  'ANTHROPIC_ORGANIZATION_ID',
  'ANTHROPIC_SERVICE_ACCOUNT_ID',
  'ANTHROPIC_WORKSPACE_ID',
  // Provider selection, and the switches that skip its auth.
  'CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH',
  'CLAUDE_CODE_SKIP_ANTHROPIC_GOOGLE_CLOUD_AUTH',
  'CLAUDE_CODE_SKIP_BEDROCK_AUTH',
  'CLAUDE_CODE_SKIP_FOUNDRY_AUTH',
  'CLAUDE_CODE_SKIP_MANTLE_AUTH',
  'CLAUDE_CODE_SKIP_VERTEX_AUTH',
  'CLAUDE_CODE_USE_ANTHROPIC_AWS',
  'CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD',
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_FOUNDRY',
  'CLAUDE_CODE_USE_GATEWAY',
  'CLAUDE_CODE_USE_MANTLE',
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

/**
 * Effort/model overrides that resolve THIS turn's own effort or model when
 * the caller leaves the field unset — as opposed to a subsystem's own model
 * (a subagent, the background classifier, a family-alias table like "which
 * model does 'opus' mean") or metadata (a model's description/name/
 * capabilities strings), none of which pick what this turn itself runs as.
 * Checked by hand against every MODEL/EFFORT-named export in the pinned SDK
 * bundle; `test/env-sdk-contract.test.ts` re-derives that same list on every
 * install so a version bump cannot add a new one unnoticed.
 *
 * Stripped only for the grade and triage phases — the two turns that promise
 * an effort floor (`models.big_grade`/`big_triage` default to 'medium' and
 * refuse 'low'), which an inherited ambient choice would otherwise quietly
 * undercut. `chat`/`edit`/`build` deliberately keep honoring the CLI's own
 * ambient default.
 */
export const GATE_ENV_VARS = ['CLAUDE_CODE_EFFORT_LEVEL', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_MODEL'] as const;

/**
 * Ambient vars that cut a gate turn's reasoning depth without naming a model
 * or an effort level, so they carry neither "MODEL" nor "EFFORT" and the scan
 * behind `GATE_ENV_VARS` cannot see them. Hand-picked rather than
 * scan-derived; `test/env-sdk-contract.test.ts` pins each name against the
 * installed bundle so a rename or removal fails loudly instead of quietly.
 */
export const GATE_THINKING_ENV_VARS = ['MAX_THINKING_TOKENS', 'CLAUDE_CODE_DISABLE_THINKING'] as const;

/**
 * `subscriptionEnv`'s result, with the gate turn's own effort/model overrides
 * (`GATE_ENV_VARS`) and thinking-depth toggles (`GATE_THINKING_ENV_VARS`)
 * removed too. Not every variable that could shape a gate turn — only the
 * ones known to name its own model, effort, or reasoning depth.
 */
export function stripGateEnv(env: Env): Env {
  const copy: Env = { ...env };
  for (const name of GATE_ENV_VARS) delete copy[name];
  for (const name of GATE_THINKING_ENV_VARS) delete copy[name];
  return copy;
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
