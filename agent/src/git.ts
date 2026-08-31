import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { rm } from 'node:fs/promises';
import { resolve } from 'node:path';
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

export interface GitOptions {
  /**
   * Extra environment for this call. Merged over `process.env`; the merge path
   * uses it to point `GIT_INDEX_FILE` at a private index, so building the
   * commit never touches the index the operator is working in.
   */
  env?: Record<string, string>;
}

export async function git(cwd: string, args: readonly string[], options: GitOptions = {}): Promise<GitResult> {
  if (cwd === '' || args.length === 0) throw new TypeError('git needs a cwd and at least one argument');
  try {
    const { stdout, stderr } = await run('git', [...BASE_ARGS, ...args], {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: MAX_OUTPUT_BYTES,
      encoding: 'utf8',
      ...(options.env === undefined ? {} : { env: { ...process.env, ...options.env } }),
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

/**
 * `rev-parse <ref>`, or null when the ref does not exist. A missing ref is an
 * ordinary answer here — the base branch may have been deleted since the build
 * — so it must not arrive as an exception the caller has to pattern-match.
 */
export async function resolveRef(repoRoot: string, ref: string): Promise<string | null> {
  try {
    const { stdout } = await git(repoRoot, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]);
    const commit = stdout.trim();
    return commit === '' ? null : commit;
  } catch {
    // `--verify --quiet` exits 1 for an unknown ref, which `git()` raises.
    return null;
  }
}

/**
 * Paths with changes git is tracking. Untracked files are deliberately NOT
 * included: a repo full of build output would never be mergeable, and git's own
 * `merge --ff-only` still refuses when an untracked file is in the way.
 */
export async function trackedChanges(repoRoot: string): Promise<string[]> {
  const { stdout } = await git(repoRoot, ['status', '--porcelain', '--untracked-files=no']);
  return stdout.split('\n').filter((line) => line.trim() !== '');
}


function detailOf(cause: unknown, args: readonly string[]): string {
  const error = cause as { stderr?: string; message?: string; code?: unknown };
  const stderr = typeof error.stderr === 'string' ? error.stderr.trim() : '';
  const base = `git ${args.join(' ')}`;
  if (stderr !== '') return `${base}: ${stderr}`;
  return `${base}: ${error.message ?? String(cause)}`;
}

/** A commit a git argument may name. Everything else is a caller's bug. */
function isCommitId(value: string): boolean {
  return /^[0-9a-f]{7,40}$/i.test(value);
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
 * The build's own repository at `commit`, HEAD detached.
 *
 * A clone, not `git worktree add`. A worktree's `.git` file points into the
 * operator's repository, and the build runs shell unattended — one
 * `git update-ref`, `git gc --prune=now` or `git reflog expire` inside it
 * reaches their refs and objects. `--local` hardlinks the object database, so
 * this costs a checkout and almost no disk, and the clone owns its own refs.
 * The hardlink is a residual: every git command is safe (git never writes an
 * object in place), but a raw write under `.git/objects` — outside git, from
 * the build's unconfined shell — reaches the same inode the source reads
 * from. Documented in the README rather than closed with `--no-hardlinks`,
 * which would cost a full object copy on every build.
 *
 * Nothing here touches the source repository: `clone` only reads it, and no
 * registration is left behind for a later `worktree prune` to have to clean up.
 */
export async function cloneAt(repoRoot: string, dir: string, commit: string): Promise<void> {
  if (!isCommitId(commit)) throw new ProtocolError('bad_request', `'${commit}' is not a commit id`);
  await git(repoRoot, ['clone', '--local', '--no-checkout', repoRoot, dir]);
  // `origin` points back at the operator's repository, and a push would write
  // their refs. The build has no reason to reach the source at all.
  await git(dir, ['remote', 'remove', 'origin']);
  await git(dir, ['checkout', '--detach', commit]);
}

/**
 * Throws the build's clone away. It is an ordinary directory with no
 * registration anywhere, so removing it is a removal and nothing more. Only
 * ever called on an explicit discard, or to clear a half-made clone.
 */
export async function removeClone(dir: string): Promise<void> {
  if (dir === '') throw new TypeError('removeClone needs a directory');
  await rm(dir, { recursive: true, force: true });
}

/**
 * Brings the source repository's `branch` into the build's clone as
 * `FETCH_HEAD`, and answers where it now points.
 *
 * The clone was made with `--local`, so it hardlinks the objects that existed
 * when it was cut and knows nothing of commits made since — a rebase onto a
 * moved base has to fetch them. A fetch only READS the source repository; the
 * clone still has no remote pointing back at it.
 */
export async function fetchBase(cloneDir: string, sourceRepo: string, branch: string): Promise<string> {
  if (branch === '') throw new TypeError('fetchBase needs a branch name');
  await git(cloneDir, ['fetch', '--no-tags', sourceRepo, branch]);
  const { stdout } = await git(cloneDir, ['rev-parse', 'FETCH_HEAD']);
  const commit = stdout.trim();
  if (!isCommitId(commit)) {
    throw new ProtocolError('agent_error', 'the fetched base did not resolve to a commit', commit);
  }
  return commit;
}

/**
 * The clone's own identity for the throwaway commit a rebase needs. It never
 * reaches the operator's history: the commit is rebased and then read back as a
 * diff, and the commit that DOES land is written with their own git identity.
 */
const CLONE_IDENTITY = {
  GIT_AUTHOR_NAME: 'nvime',
  GIT_AUTHOR_EMAIL: 'nvime@localhost',
  GIT_COMMITTER_NAME: 'nvime',
  GIT_COMMITTER_EMAIL: 'nvime@localhost',
};

/** True while a rebase is stopped part-way through, waiting to be resolved. */
export async function rebaseInProgress(cloneDir: string): Promise<boolean> {
  for (const name of ['rebase-merge', 'rebase-apply']) {
    const { stdout } = await git(cloneDir, ['rev-parse', '--git-path', name]);
    const path = stdout.trim();
    if (path !== '' && existsSync(resolve(cloneDir, path))) return true;
  }
  return false;
}

/**
 * Moves the build's work onto `newBase`, in the clone and nowhere else.
 *
 * The build is told not to commit, so its work is an uncommitted tree; git can
 * only rebase commits, so it is committed here first. That commit is disposable
 * — the capture that follows diffs the clone against the base regardless of
 * whether the work is committed.
 *
 * Returns whether git stopped on conflicts. A conflicted rebase is LEFT in
 * progress on purpose: resolving it is the agent turn's job, and aborting here
 * would throw away the half of it git already did.
 */
export async function rebaseCloneOnto(cloneDir: string, newBase: string): Promise<{ conflicted: boolean }> {
  if (!isCommitId(newBase)) throw new ProtocolError('bad_request', `'${newBase}' is not a commit id`);
  await git(cloneDir, ['add', '-A']);
  const dirty = await hasStagedChanges(cloneDir);
  if (dirty) {
    await git(cloneDir, ['commit', '-m', 'nvime: work in progress'], { env: CLONE_IDENTITY });
  }
  try {
    // Replaying commits writes new commit objects even when nothing conflicts,
    // so the clone's own identity has to travel with this call too — not just
    // the WIP commit above — or a runner with no global git config fails here.
    await git(cloneDir, ['rebase', newBase], { env: CLONE_IDENTITY });
    return { conflicted: false };
  } catch (cause) {
    if (await rebaseInProgress(cloneDir)) return { conflicted: true };
    throw cause;
  }
}

/** Puts the clone back on `commit`, discarding a rebase git could not finish. */
export async function abortRebase(cloneDir: string): Promise<void> {
  await git(cloneDir, ['rebase', '--abort']);
}

async function hasStagedChanges(cloneDir: string): Promise<boolean> {
  const { stdout } = await git(cloneDir, ['diff', '--cached', '--name-only']);
  return stdout.trim() !== '';
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
export async function captureDiff(buildDir: string, baseCommit: string): Promise<string> {
  if (!isCommitId(baseCommit)) {
    throw new ProtocolError('bad_request', `'${baseCommit}' is not a commit id`);
  }
  await git(buildDir, ['add', '-A', '-N']);
  const { stdout } = await git(buildDir, ['diff', '--no-ext-diff', '--find-renames', baseCommit]);
  if (Buffer.byteLength(stdout, 'utf8') > MAX_DIFF_BYTES) {
    throw new ProtocolError(
      'agent_error',
      'the build produced a diff too large to review',
      `over ${MAX_DIFF_BYTES} bytes`,
    );
  }
  return stdout;
}
