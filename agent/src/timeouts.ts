/**
 * The bounded operations a request handler can be waiting on, kept in one
 * place so a shutdown's drain window can be derived from them instead of
 * hand-tuned separately (the two drifted apart once already: a 5s drain
 * against a 10s version probe dropped a `ping` it had already accepted).
 */

/** Bounds `readClaudeVersion`, the only slow step a `ping` can be waiting on. */
export const CLAUDE_VERSION_PROBE_TIMEOUT_MS = 10_000;

/**
 * Bounds one git call. Generous: `worktree add` on a large repo checks out a
 * whole tree, and a capture diffs it again.
 */
export const GIT_TIMEOUT_MS = 120_000;

/** How long a shutdown waits for in-flight requests to answer before exiting. */
export const DRAIN_TIMEOUT_MS = CLAUDE_VERSION_PROBE_TIMEOUT_MS + 2000;
