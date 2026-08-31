import { rmSync } from 'node:fs';
import type { BigSession } from './bigstore.js';
import { git, readHead, resolveRef, trackedChanges } from './git.js';
import { ProtocolError } from './protocol.js';
import type { TriageCounts } from './triage.js';
import type { ParsedDiff } from './unidiff.js';

/**
 * The local merge: the one place nvime writes to the operator's repository.
 *
 * It is built so there is exactly ONE command that can change what they see —
 * the final `merge --ff-only`. Everything before it happens in a private index
 * file outside the repository, so an interruption at any earlier point leaves
 * their index, working tree and branches byte for byte as they were.
 *
 *   read-tree  <base>            into GIT_INDEX_FILE=<private>
 *   apply --cached <patch>       (retried with --3way)
 *   write-tree                   -> the reviewed tree
 *   commit-tree  -p <base>       -> the commit
 *   update-ref  <branch> <c> ''  -> creates the branch, refusing to overwrite
 *   merge --ff-only <branch>     -> the only step that touches their checkout
 *
 * Nothing here asks whether the review is finished. That is `checkMerge`'s job,
 * and the service re-runs it immediately before calling this — a caller that
 * skipped it would be landing an undefended change, so the two are never
 * collapsed into one pass.
 */

/** Every reason a merge can be refused. The editor branches on `code`. */
export type MergeRefusalCode =
  | 'not-reviewing'
  | 'already-merged'
  | 'threads-open'
  | 'nothing-to-merge'
  | 'no-diff'
  | 'binary-change'
  | 'no-base-branch'
  | 'base-gone'
  | 'base-moved'
  | 'dirty-tree'
  | 'not-on-base'
  | 'held-elsewhere';

export interface MergeRefusal {
  code: MergeRefusalCode;
  /** One line, in the reviewer's words, naming what stands in the way. */
  message: string;
}

export interface LandRequest {
  repoRoot: string;
  /** The branch nvime creates at `baseCommit` and lands. */
  branch: string;
  baseBranch: string;
  baseCommit: string;
  /** Absolute path of the verified diff on disk. */
  patchPath: string;
  /** Commit message: the session title, and nothing about who wrote it. */
  message: string;
  /** Absolute path for the private index. Must be outside the repository. */
  indexFile: string;
}

export interface LandResult {
  commit: string;
  branch: string;
}

/** What `checkMerge` is told about the session, so it reads no state twice. */
export interface MergeFacts {
  /** The captured diff, parsed — null when it does not verify against `diffId`. */
  diff: ParsedDiff | null;
  counts: TriageCounts;
  /** Another editor holds a live claim on this session. */
  heldElsewhere: boolean;
}

/**
 * Everything that must be true before nvime writes to the operator's repo,
 * evaluated in full so the reader is told all of it at once rather than one
 * refusal per attempt.
 *
 * This is the ONLY definition of "mergeable". The editor calls it to draw the
 * gate line, and `BigService.merge` calls it again immediately before landing —
 * never trusting the first answer, which was computed for a screen the reader
 * may have been looking at for an hour.
 */
export async function checkMerge(session: BigSession, facts: MergeFacts): Promise<MergeRefusal[]> {
  const refusals: MergeRefusal[] = [];
  const push = (code: MergeRefusalCode, message: string): void => {
    refusals.push({ code, message });
  };

  if (session.state === 'merged') push('already-merged', 'this change has already been merged');
  else if (session.state !== 'reviewing') push('not-reviewing', `this change is still ${session.state}`);
  if (facts.heldElsewhere) push('held-elsewhere', 'another editor is driving this change');
  if (facts.counts.open > 0) {
    const open = facts.counts.open;
    push('threads-open', `${open} thread${open === 1 ? '' : 's'} still ${open === 1 ? 'needs' : 'need'} clearing`);
  }
  if (facts.diff === null) push('no-diff', 'the captured diff is not the one these threads describe');
  else if (facts.diff.hunks.length === 0) push('nothing-to-merge', 'the build changed nothing');
  else {
    // A diff captured without `--binary` describes these files but carries none
    // of their bytes, so naming them is the only way forward: the reader either
    // gitignores build output the clone produced, or asks the build to drop it.
    const binary = facts.diff.files.filter((file) => file.binary).map((file) => file.path);
    if (binary.length > 0) {
      push('binary-change', `the reviewed diff does not carry the bytes of ${binary.join(', ')}`);
    }
  }

  const base = session.base;
  if (base === null || base.branch === null) {
    push('no-base-branch', 'this change was built from a detached HEAD, so there is no branch to merge into');
    return refusals;
  }
  refusals.push(...(await checkRepoState(session.repoRoot, base.branch, base.commit)));
  return refusals;
}

/** The operator's repository right now: the branch, where it is, and its tree. */
async function checkRepoState(repoRoot: string, baseBranch: string, baseCommit: string): Promise<MergeRefusal[]> {
  const refusals: MergeRefusal[] = [];
  const head = await readHead(repoRoot);
  if (head.branch !== baseBranch) {
    const where = head.branch === null ? 'a detached HEAD' : head.branch;
    refusals.push({ code: 'not-on-base', message: `you are on ${where}; check out ${baseBranch} to merge` });
  }
  const now = await resolveRef(repoRoot, baseBranch);
  if (now === null) {
    refusals.push({ code: 'base-gone', message: `${baseBranch} no longer exists` });
  } else if (now !== baseCommit) {
    refusals.push({
      code: 'base-moved',
      message: `${baseBranch} has moved since the build started (${baseCommit.slice(0, 8)} → ${now.slice(0, 8)})`,
    });
  }
  const dirty = await trackedChanges(repoRoot);
  if (dirty.length > 0) {
    refusals.push({
      code: 'dirty-tree',
      message: `${dirty.length} tracked file(s) have uncommitted changes — commit or stash them first`,
    });
  }
  return refusals;
}

/**
 * Branch name for a session's change: `nvime/big/<slug>`. Derived from the
 * title, so the operator recognizes it in `git branch` a month later.
 */
export function branchNameFor(title: string, sessionId: string): string {
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40)
    .replace(/-+$/g, '');
  return `nvime/big/${slug === '' ? sessionId : slug}`;
}

/**
 * Builds the commit and fast-forwards the base branch into it.
 *
 * On any failure past the point where the branch exists, the branch is deleted
 * again and the repository is re-checked: the caller is told the merge failed
 * AND whether the rollback actually restored things, never just the first.
 *
 * @throws ProtocolError with the failure and the verified rollback state.
 */
export async function landDiff(request: LandRequest): Promise<LandResult> {
  const { repoRoot, branch, baseBranch, baseCommit, indexFile } = request;
  const ref = `refs/heads/${branch}`;
  let commit: string | null = null;
  try {
    commit = await buildCommit(request);
    // Empty old value: creates the ref and fails if anything already holds it,
    // in one atomic step rather than an exists-check and a race.
    await git(repoRoot, ['update-ref', ref, commit, '']);
    await fastForward(repoRoot, branch, baseBranch, baseCommit, commit);
    return { commit, branch };
  } catch (cause) {
    const rolledBack = await rollback(repoRoot, ref, commit, baseBranch, baseCommit);
    throw asMergeFailure(cause, rolledBack);
  } finally {
    // The private index is scratch: it holds the tree that is now a commit.
    rmSync(indexFile, { force: true });
  }
}

/** The reviewed diff as a commit on top of `baseCommit`. Touches no ref. */
async function buildCommit(request: LandRequest): Promise<string> {
  const { repoRoot, baseCommit, patchPath, message, indexFile } = request;
  const env = { GIT_INDEX_FILE: indexFile };
  await git(repoRoot, ['read-tree', baseCommit], { env });
  await applyPatch(repoRoot, patchPath, env);
  const { stdout: tree } = await git(repoRoot, ['write-tree'], { env });
  const { stdout } = await git(repoRoot, ['commit-tree', tree.trim(), '-p', baseCommit, '-m', message]);
  const commit = stdout.trim();
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProtocolError('agent_error', 'git did not return a commit for the reviewed diff', commit);
  }
  return commit;
}

/**
 * Applies the patch to the private index. A clean apply is tried first: `--3way`
 * can resolve a hunk from the blobs it names, which is what makes it useful,
 * but it also leaves conflict stages in the index that `write-tree` then
 * refuses — so its failure has to read as a conflict, not as a git crash.
 */
async function applyPatch(repoRoot: string, patchPath: string, env: Record<string, string>): Promise<void> {
  const args = ['apply', '--cached', '--whitespace=nowarn'];
  try {
    await git(repoRoot, [...args, patchPath], { env });
    return;
  } catch (clean) {
    try {
      await git(repoRoot, [...args, '--3way', patchPath], { env });
      return;
    } catch (threeWay) {
      throw new ProtocolError(
        'agent_error',
        'the reviewed diff no longer applies to this repository',
        `${detailOf(clean)}\n${detailOf(threeWay)}`,
      );
    }
  }
}

/**
 * The last step, and the only one the operator can see. Re-reads the base under
 * the run's lock first: a base that moved while the commit was being built must
 * stop here, with the branch left in place for the reader to merge themselves.
 */
async function fastForward(
  repoRoot: string,
  branch: string,
  baseBranch: string,
  baseCommit: string,
  commit: string,
): Promise<void> {
  const now = await resolveRef(repoRoot, baseBranch);
  if (now !== baseCommit) {
    throw new ProtocolError(
      'agent_error',
      `${baseBranch} moved while the merge was being prepared`,
      `the reviewed change is on ${branch}; merge it yourself when you have looked at what landed`,
    );
  }
  await git(repoRoot, ['merge', '--ff-only', branch]);
  const landed = await resolveRef(repoRoot, baseBranch);
  if (landed !== commit) {
    throw new ProtocolError(
      'agent_error',
      `${baseBranch} is not at the merged commit`,
      `expected ${commit}, found ${landed ?? 'nothing'}`,
    );
  }
}

/** Rollback state, so a failure can say what it left behind rather than guess. */
interface Rollback {
  ok: boolean;
  detail: string;
}

/**
 * Undoes whatever the failed attempt managed to do, then PROVES it: the base
 * branch is back where it was and no tracked file changed. A rollback that
 * cannot be verified is reported as such — the one thing worse than a failed
 * merge is a failed merge that claims it cleaned up.
 */
async function rollback(
  repoRoot: string,
  ref: string,
  commit: string | null,
  baseBranch: string,
  baseCommit: string,
): Promise<Rollback> {
  try {
    // Compare-and-delete: only the ref this attempt created, and only while it
    // still points where this attempt put it.
    if (commit !== null) await deleteIfOurs(repoRoot, ref, commit);
    const base = await resolveRef(repoRoot, baseBranch);
    if (base !== baseCommit) {
      return { ok: false, detail: `${baseBranch} is at ${short(base)}, not the base ${short(baseCommit)}` };
    }
    const dirty = await trackedChanges(repoRoot);
    if (dirty.length > 0) {
      return { ok: false, detail: `${dirty.length} tracked file(s) are modified: ${dirty.slice(0, 5).join(', ')}` };
    }
    return { ok: true, detail: 'the repository is exactly as it was' };
  } catch (cause) {
    return { ok: false, detail: `the rollback check itself failed: ${detailOf(cause)}` };
  }
}

async function deleteIfOurs(repoRoot: string, ref: string, commit: string): Promise<void> {
  try {
    await git(repoRoot, ['update-ref', '-d', ref, commit]);
  } catch (cause) {
    // Either it was never created, or it has since moved and is not ours to
    // delete. Both are reasons to leave it; neither invalidates the rollback.
    process.stderr.write(`nvime: left ${ref} in place: ${detailOf(cause)}\n`);
  }
}

function asMergeFailure(cause: unknown, rolledBack: Rollback): ProtocolError {
  const base = cause instanceof ProtocolError ? cause : null;
  const message = base?.message ?? (cause instanceof Error ? cause.message : String(cause));
  const detail = [base?.detail, rolledBack.ok ? `rolled back: ${rolledBack.detail}` : `ROLLBACK: ${rolledBack.detail}`]
    .filter((part) => part !== undefined && part !== '')
    .join('\n');
  return new ProtocolError(rolledBack.ok ? 'bad_request' : 'agent_error', message, detail);
}

function detailOf(cause: unknown): string {
  if (cause instanceof ProtocolError) return cause.detail ?? cause.message;
  return cause instanceof Error ? cause.message : String(cause);
}

function short(commit: string | null): string {
  return commit === null ? 'nothing' : commit.slice(0, 8);
}
