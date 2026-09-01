import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { describe, it } from 'node:test';
import { GATE_ENV_VARS, STRIPPED_ENV_VARS } from '../src/env.js';

/**
 * `STRIPPED_ENV_VARS` is a hand-written list, and a hand-written list rots: the
 * first version named a variable the SDK has never read while missing four it
 * does. This test re-derives the risk class from the SDK bundle that is
 * actually installed, so a version bump that introduces a new credential or a
 * new endpoint override fails here instead of leaking silently.
 */
const SDK_BUNDLE = createRequire(import.meta.url).resolve('@anthropic-ai/claude-agent-sdk');

/** Scope: what the spawned `claude` reads. The browser bridge is not in play. */
const OWNED_PREFIX = /^(_?CLAUDE_CODE|ANTHROPIC|AWS_BEARER)_/;
const CARRIES_A_CREDENTIAL =
  /(API_KEY|AUTH_TOKEN|OAUTH_TOKEN|BEARER_TOKEN|ACCESS_TOKEN|REFRESH_TOKEN|IDENTITY_TOKEN|CLIENT_CERT|CLIENT_KEY|CERT_STORE|AUTH_HELPER)/;
const REDIRECTS_TRAFFIC = /(BASE_URL|OAUTH_URL|CUSTOM_HEADERS|UNIX_SOCKET)/;
const SELECTS_A_PROVIDER =
  /^CLAUDE_CODE_(USE_|SKIP_[A-Z0-9_]*AUTH$)|^ANTHROPIC_(PROFILE|CONFIG_DIR|SCOPE|ORGANIZATION_ID|SERVICE_ACCOUNT_ID|WORKSPACE_ID)$/;

/**
 * Names that match the shapes above but threaten neither guarantee. Each entry
 * is a decision, not an exemption: adding one means arguing that the variable
 * cannot supply a credential and cannot move model traffic.
 */
const ALLOWED_UNSTRIPPED = new Map([
  ['CLAUDE_CODE_API_KEY_HELPER_TTL_MS', 'a cache lifetime, not a key'],
  ['CLAUDE_CODE_ARTIFACTS_API_BASE_URL', 'artifact service, not model traffic'],
  ['CLAUDE_CODE_ARTIFACT_ASSET_BASE_URL', 'artifact service, not model traffic'],
  ['CLAUDE_CODE_ARTIFACT_LIVE_BASE_URL', 'artifact service, not model traffic'],
  ['CLAUDE_CODE_ARTIFACT_SYNC_BASE_URL', 'artifact service, not model traffic'],
  ['CLAUDE_CODE_ARTIFACT_VIEWER_BASE_URL', 'artifact service, not model traffic'],
  ['CLAUDE_CODE_GB_BASE_URL', 'ancillary service, not model traffic'],
  ['CLAUDE_CODE_MEMORY_API_BASE_URL', 'memory service, not model traffic'],
  ['CLAUDE_CODE_USE_COWORK_PLUGINS', 'feature flag, not a provider'],
  ['CLAUDE_CODE_USE_NATIVE_FILE_SEARCH', 'feature flag, not a provider'],
  ['CLAUDE_CODE_USE_POWERSHELL_TOOL', 'feature flag, not a provider'],
  [
    'CLAUDE_CODE_ENABLE_PROXY_AUTH_HELPER',
    'only exercised behind HTTPS_PROXY/HTTP_PROXY/ALL_PROXY, which nvime ' +
      'deliberately leaves alone (see the README) — nothing to strip here that ' +
      "isn't already the proxy's own scope",
  ],
  ['CLAUDE_CODE_PROXY_AUTH_HELPER_TTL_MS', 'a cache lifetime, not a credential'],
]);

/** Every credential/routing/provider name the installed bundle mentions. */
function scanBundle(): string[] {
  const source = readFileSync(SDK_BUNDLE, 'utf8');
  const names = new Set(source.match(/_?[A-Z][A-Z0-9_]{3,}/g) ?? []);
  return [...names]
    .filter(
      (name) =>
        OWNED_PREFIX.test(name) &&
        (CARRIES_A_CREDENTIAL.test(name) ||
          REDIRECTS_TRAFFIC.test(name) ||
          SELECTS_A_PROVIDER.test(name)),
    )
    .sort();
}

describe('the strip list against the installed SDK', () => {
  const found = scanBundle();

  it('scans a bundle that really carries the known provider variables', () => {
    // Without this, a regex that matches nothing would make every check below
    // pass vacuously — the exact failure mode this file exists to prevent.
    for (const anchor of ['ANTHROPIC_API_KEY', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK']) {
      assert.ok(found.includes(anchor), `the scan must find ${anchor} in ${SDK_BUNDLE}`);
    }
    assert.ok(found.length > 20, `only ${found.length} names found; the scan looks broken`);
  });

  it('strips or explicitly allows every one of them', () => {
    const stripped = new Set<string>(STRIPPED_ENV_VARS);
    const unaccounted = found.filter(
      (name) => !stripped.has(name) && !ALLOWED_UNSTRIPPED.has(name),
    );
    assert.deepEqual(
      unaccounted,
      [],
      'the SDK reads these and nvime neither strips nor allows them; add each to ' +
        'STRIPPED_ENV_VARS, or to ALLOWED_UNSTRIPPED with the reason it is harmless',
    );
  });

  it('names nothing the installed SDK does not read', () => {
    const phantom = STRIPPED_ENV_VARS.filter((name) => !found.includes(name));
    assert.deepEqual(phantom, [], 'a name the SDK never reads is a list written from memory');
  });

  it('keeps the allowlist honest: every entry is a name still in the bundle', () => {
    const stale = [...ALLOWED_UNSTRIPPED.keys()].filter((name) => !found.includes(name));
    assert.deepEqual(stale, [], 'these were allowed against an SDK that no longer reads them');
  });
});

/**
 * `GATE_ENV_VARS` (env.ts) is a second, narrower hand-written list: not every
 * credential/routing name, but every MODEL/EFFORT-named one that resolves a
 * turn's OWN model or effort — the risk `stripGateEnv` exists to remove for
 * the grade and triage phases. Re-derived the same way as the strip list
 * above, so an SDK bump that renames `CLAUDE_CODE_EFFORT_LEVEL` or introduces
 * a sibling fails here instead of leaving the gate's floor silently porous.
 */
const MODEL_OR_EFFORT_NAMED = /MODEL|EFFORT/;

/**
 * Every other MODEL/EFFORT-named export the bundle carries, and why it is not
 * this turn's own resolved model/effort. Each entry is a decision: adding one
 * means arguing the variable cannot pick what THIS turn — not a subagent, not
 * a background subsystem, not a picker label — runs as.
 */
const GATE_ALLOWED_UNSTRIPPED = new Map([
  ['ANTHROPIC_CUSTOM_MODEL_OPTION', 'a picker entry for a custom model, not a resolved override'],
  ['ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION', 'picker label text'],
  ['ANTHROPIC_CUSTOM_MODEL_OPTION_NAME', 'picker label text'],
  ['ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES', 'picker metadata'],
  ['ANTHROPIC_DEFAULT_FABLE_MODEL', "a family-alias table entry (what 'fable' means), not a resolved override"],
  ['ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION', 'picker label text'],
  ['ANTHROPIC_DEFAULT_FABLE_MODEL_NAME', 'picker label text'],
  ['ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES', 'picker metadata'],
  ['ANTHROPIC_DEFAULT_HAIKU_MODEL', "a family-alias table entry (what 'haiku' means), not a resolved override"],
  ['ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION', 'picker label text'],
  ['ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME', 'picker label text'],
  ['ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES', 'picker metadata'],
  ['ANTHROPIC_DEFAULT_OPUS_MODEL', "a family-alias table entry (what 'opus' means), not a resolved override"],
  ['ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION', 'picker label text'],
  ['ANTHROPIC_DEFAULT_OPUS_MODEL_NAME', 'picker label text'],
  ['ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES', 'picker metadata'],
  ['ANTHROPIC_DEFAULT_SONNET_MODEL', "a family-alias table entry (what 'sonnet' means), not a resolved override"],
  ['ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION', 'picker label text'],
  ['ANTHROPIC_DEFAULT_SONNET_MODEL_NAME', 'picker label text'],
  ['ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES', 'picker metadata'],
  ['ANTHROPIC_SMALL_FAST_MODEL', 'routes internal helper calls (e.g. title generation), not this turn'],
  ['ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION', 'routing for the helper-call model above'],
  ['CLAUDE_CODE_ALWAYS_ENABLE_EFFORT', 'a feature flag enabling effort at all, not an effort value'],
  ['CLAUDE_CODE_AUTO_MODE_MODEL', "auto-mode's own model selection, a different feature entirely"],
  ['CLAUDE_CODE_BG_CLASSIFIER_MODEL', 'the background classifier subsystem, not this turn'],
  ['CLAUDE_CODE_COORDINATOR_FORCE_WORKER_INHERIT_MODEL', 'a multi-agent coordinator feature nvime never drives'],
  ['CLAUDE_CODE_DISABLE_LEGACY_MODEL_REMAP', 'a boolean toggle, not a model value'],
  ['CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT', 'a boolean toggle, not a model value'],
  ['CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY', 'a boolean toggle, not a model value'],
  ['CLAUDE_CODE_MODEL_CATALOG', "the picker's own catalog, not a resolved override"],
  ['CLAUDE_CODE_NO_MODEL_FALLBACK', 'a boolean toggle, not a model value'],
  [
    'CLAUDE_CODE_SUBAGENT_MODEL',
    "a Task subagent's own model — nvime denies the Task/Agent tools on every turn, so no subagent ever runs",
  ],
]);

describe('the gate env additions against the installed SDK', () => {
  const source = readFileSync(SDK_BUNDLE, 'utf8');
  const found = [...new Set(source.match(/_?[A-Z][A-Z0-9_]{3,}/g) ?? [])]
    .filter((name) => OWNED_PREFIX.test(name) && MODEL_OR_EFFORT_NAMED.test(name))
    .sort();

  it('scans a bundle that really carries the known model/effort variables', () => {
    for (const anchor of ['ANTHROPIC_MODEL', 'CLAUDE_CODE_EFFORT_LEVEL']) {
      assert.ok(found.includes(anchor), `the scan must find ${anchor} in ${SDK_BUNDLE}`);
    }
    assert.ok(found.length > 10, `only ${found.length} names found; the scan looks broken`);
  });

  it('strips or explicitly excludes every one of them', () => {
    const stripped = new Set<string>(GATE_ENV_VARS);
    const unaccounted = found.filter((name) => !stripped.has(name) && !GATE_ALLOWED_UNSTRIPPED.has(name));
    assert.deepEqual(
      unaccounted,
      [],
      'the SDK reads these and nvime neither strips them for a gate turn nor excludes them — add each to ' +
        'GATE_ENV_VARS, or to GATE_ALLOWED_UNSTRIPPED with the reason it cannot resolve a turn\'s own model/effort',
    );
  });

  it('names nothing the installed SDK does not read', () => {
    const phantom = GATE_ENV_VARS.filter((name) => !found.includes(name));
    assert.deepEqual(phantom, [], 'a name the SDK never reads is a list written from memory');
  });

  it('keeps the exclusion list honest: every entry is a name still in the bundle', () => {
    const stale = [...GATE_ALLOWED_UNSTRIPPED.keys()].filter((name) => !found.includes(name));
    assert.deepEqual(stale, [], 'these were excluded against an SDK that no longer reads them');
  });
});
