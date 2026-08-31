import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { ProtocolError } from './protocol.js';
import { GIT_TIMEOUT_MS } from './timeouts.js';
import { MAX_DIFF_BYTES } from './unidiff.js';

/**
 * Every git call big-change mode makes. One place, so the flags that keep a
 * capture parseable — no colour, no pager, no path quoting — cannot be
 * forgotten at one call site, and so a git failure always reaches the editor
 * as a named error instead of a raw exit status.
 */

const run = promisify(execFile);

/** Room for the largest diff `capture` will accept, plus git's own chatter. */
const MAX_OUTPUT_BYTES = MAX_DIFF_BYTES + 1024 * 1024;

/** Flags before the subcommand: git must not read the user's config for these. */
const BASE_ARGS = ['--no-pager', '-c', 'core.quotePath=false', '-c', 'color.ui=false'];

export interface GitResult {
  stdout: string;
  stderr: string;
}

export async function git(cwd: string, args: readonly string[]): Promise<GitResult> {
  if (cwd === '' || args.length === 0) throw new TypeError('git needs a cwd and at least one argument');
  try {
    const { stdout, stderr } = await run('git', [...BASE_ARGS, ...args], {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: MAX_OUTPUT_BYTES,
      encoding: 'utf8',
    });
    return { stdout, stderr };
  } catch (cause) {
    throw new ProtocolError(
      'agent_error',
      `git ${args[0]} failed`,
      detailOf(cause, args),
    );
  }
}

function detailOf(cause: unknown, args: readonly string[]): string {
  const error = cause as { stderr?: string; message?: string; code?: unknown };
  const stderr = typeof error.stderr === 'string' ? error.stderr.trim() : '';
  const base = `git ${args.join(' ')}`;
  if (stderr !== '') return `${base}: ${stderr}`;
  return `${base}: ${error.message ?? String(cause)}`;
}

export interface RepoHead {
  commit: string;
  /** The branch HEAD was on, or null when the repo is already detached. */
  branch: string | null;
}

/** Where a build should branch from. Read once and recorded, never re-derived. */
export async function readHead(repoRoot: string): Promise<RepoHead> {
  const { stdout: commit } = await git(repoRoot, ['rev-parse', 'HEAD']);
  const { stdout: branch } = await git(repoRoot, ['rev-parse', '--abbrev-ref', 'HEAD']);
  const name = branch.trim();
  return { commit: commit.trim(), branch: name === 'HEAD' ? null : name };
}

/**
 * A detached worktree at `commit`. Detached on purpose: the build must not
 * move, or lock, any branch the user might be sitting on.
 */
export async function addWorktree(repoRoot: string, dir: string, commit: string): Promise<void> {
  // A worktree directory deleted from underneath git stays registered, and the
  // add then fails on a path nothing is using. Pruning first makes re-approving
  // a session whose worktree was removed by hand work instead of wedging it.
  await git(repoRoot, ['worktree', 'prune']);
  await git(repoRoot, ['worktree', 'add', '--detach', dir, commit]);
}

/**
 * Drops a worktree and the registration pointing at it. `--force` is required
 * because a build leaves uncommitted work behind by design; this is only ever
 * called on an explicit discard, never as cleanup after a failure.
 */
export async function removeWorktree(repoRoot: string, dir: string): Promise<void> {
  await git(repoRoot, ['worktree', 'remove', '--force', dir]);
}

/**
 * The build's whole output as one diff against the base commit.
 *
 * `add -A -N` first: a file the agent created is untracked, and `git diff`
 * would not mention it at all — the reviewer would be shown a change set with
 * the new files missing. Intent-to-add makes them diffable without committing.
 *
 * Compared against the base COMMIT rather than the index, so a build that
 * committed anyway (it is told not to, and cannot be stopped from it) is still
 * captured in full.
 */
export async function captureDiff(worktreeDir: string, baseCommit: string): Promise<string> {
  if (!/^[0-9a-f]{7,40}$/i.test(baseCommit)) {
    throw new ProtocolError('bad_request', `'${baseCommit}' is not a commit id`);
  }
  await git(worktreeDir, ['add', '-A', '-N']);
  const { stdout } = await git(worktreeDir, ['diff', '--no-ext-diff', '--find-renames', baseCommit]);
  if (Buffer.byteLength(stdout, 'utf8') > MAX_DIFF_BYTES) {
    throw new ProtocolError(
      'agent_error',
      'the build produced a diff too large to review',
      `over ${MAX_DIFF_BYTES} bytes`,
    );
  }
  return stdout;
}
