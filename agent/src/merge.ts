import { rmSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import type { BigSession } from './bigstore.js';
import { git, readHead, resolveRef, trackedChanges, type RepoHead } from './git.js';
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
  | 'merged-elsewhere'
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
  refusals.push(...(await checkRepoState(session, base.branch, base.commit)));
  return refusals;
}

/** The operator's repository right now: the branch, where it is, and its tree. */
async function checkRepoState(session: BigSession, baseBranch: string, baseCommit: string): Promise<MergeRefusal[]> {
  const repoRoot = session.repoRoot;
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
    refusals.push(await movedOrLanded(session, baseBranch, baseCommit, now));
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
 * The branch names a session's land may have used, in the order it tries them.
 * One list, so "where would this have landed" and "where did it land" cannot
 * drift apart.
 */
export function branchCandidates(title: string, sessionId: string): string[] {
  const preferred = branchNameFor(title, sessionId);
  return [preferred, `${preferred}-${sessionId}`];
}

/**
 * Why the base branch is not where the build left it. A base that moved
 * because THIS change landed on it is not the base moving out from under the
 * reader — it is a merge whose record write did not survive — and telling them
 * to rebase onto their own just-landed change is the worst answer available.
 */
async function movedOrLanded(
  session: BigSession,
  baseBranch: string,
  baseCommit: string,
  now: string,
): Promise<MergeRefusal> {
  const landed = await landedAlready(session, baseBranch, baseCommit);
  if (landed !== null) {
    return {
      code: 'merged-elsewhere',
      message: `this change already landed as ${landed.commit.slice(0, 8)} on ${baseBranch}`,
    };
  }
  return {
    code: 'base-moved',
    message: `${baseBranch} has moved since the build started (${baseCommit.slice(0, 8)} → ${now.slice(0, 8)})`,
  };
}

/**
 * The reviewed change already on the base branch, under the branch THIS
 * session's own land attempt pinned to its record before it ran. Three checks,
 * all required: the ref must sit directly on the recorded base
 * (`commit-tree -p <baseCommit>`), its tree must be the one this session's
 * diff was pinned to build, and the base branch must contain it.
 *
 * Deliberately not a title-derived guess: two sessions opened with the same
 * title share a preferred branch name, and a name-only match would let one
 * claim the other's landing. `landAttempt` is set once, immediately before this
 * session's own `landDiff`, so nothing but this session's own prior attempt can
 * satisfy it. Null (no attempt ever pinned) always answers "no" — a base that
 * moved before this session tried to land is never mistaken for a landing.
 * Only asked when the base has moved, so the ordinary path pays nothing for it.
 */
export async function landedAlready(
  session: BigSession,
  baseBranch: string,
  baseCommit: string,
): Promise<LandResult | null> {
  const attempt = session.landAttempt;
  if (attempt === null) return null;
  const commit = await resolveRef(session.repoRoot, `refs/heads/${attempt.branch}`);
  if (commit === null) return null;
  if ((await resolveRef(session.repoRoot, `${commit}^`)) !== baseCommit) return null;
  if ((await treeOf(session.repoRoot, commit)) !== attempt.tree) return null;
  if (!(await contains(session.repoRoot, baseBranch, commit))) return null;
  return { commit, branch: attempt.branch };
}

/** The tree a commit holds, so a name-and-parent match can still be told apart
 *  from a same-named branch that carries different content. */
async function treeOf(repoRoot: string, commit: string): Promise<string> {
  const { stdout } = await git(repoRoot, ['rev-parse', `${commit}^{tree}`]);
  return stdout.trim();
}

/** Whether `branch` already holds `commit`. Counted rather than exit-coded:
 *  `merge-base --is-ancestor` reports "no" and "broken repo" the same way. */
async function contains(repoRoot: string, branch: string, commit: string): Promise<boolean> {
  const { stdout } = await git(repoRoot, ['rev-list', '--count', `${branch}..${commit}`]);
  return stdout.trim() === '0';
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
  requirePrivateIndex(repoRoot, indexFile);
  const startedAt = Date.now();
  const ref = `refs/heads/${branch}`;
  // Read before anything is attempted: the rollback proof compares against
  // what this attempt FOUND, not against an absolute "clean and on the base".
  const before: RepoState = { head: await readHead(repoRoot), dirty: await trackedChanges(repoRoot) };
  let commit: string | null = null;
  try {
    commit = await buildCommit(request, startedAt);
    // Empty old value: creates the ref and fails if anything already holds it,
    // in one atomic step rather than an exists-check and a race.
    await git(repoRoot, ['update-ref', ref, commit, '']);
    await fastForward(repoRoot, branch, baseBranch, baseCommit, commit);
    return { commit, branch };
  } catch (cause) {
    throw asMergeFailure(cause, await rollback({ repoRoot, ref, commit, baseBranch, baseCommit, before }));
  } finally {
    // The private index is scratch: it holds the tree that is now a commit. Its
    // lock goes with it — a killed `git apply` leaves one behind, and git then
    // refuses every later merge of this session with a message that sends the
    // reader hunting for a stray process in their own repository.
    rmSync(indexFile, { force: true });
    rmSync(lockOf(indexFile), { force: true });
  }
}

/** The repository as an attempt found it, so a rollback can prove it undid itself. */
interface RepoState {
  head: RepoHead;
  /** `git status` lines, so a tree that was already dirty is not blamed on us. */
  dirty: string[];
}

/**
 * The private index must live outside the repository. Everything before the
 * fast-forward is invisible to the operator only because it is written there,
 * and the lock cleanup above would otherwise delete a lock in THEIR index.
 */
function requirePrivateIndex(repoRoot: string, indexFile: string): void {
  const root = resolve(repoRoot);
  const index = resolve(indexFile);
  if (index === root || index.startsWith(`${root}/`)) {
    throw new ProtocolError('internal', 'the merge index must live outside the repository', index);
  }
}

function lockOf(indexFile: string): string {
  return `${indexFile}.lock`;
}

/**
 * Clears a private-index lock left behind by a killed `git apply`.
 *
 * Stale by construction and by check: the index is nvime's own scratch file in
 * its own store, this session's run claim is held, and the lock was already
 * there when this attempt began. One that appeared SINCE is something else
 * writing the file, which is a refusal naming the real path — never a silent
 * removal, and never git's "another git process in this repository".
 */
function clearStaleIndexLock(indexFile: string, startedAt: number): void {
  const lock = lockOf(indexFile);
  let mtimeMs: number;
  try {
    mtimeMs = statSync(lock).mtimeMs;
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return;
    throw cause;
  }
  if (mtimeMs > startedAt) {
    throw new ProtocolError(
      'agent_error',
      'the private index for this merge is locked by something still running',
      `${lock} was written after this merge began; nothing but nvime writes it`,
    );
  }
  rmSync(lock, { force: true });
  process.stderr.write(`nvime: cleared a stale private-index lock at ${lock}\n`);
}

/** The reviewed diff as a commit on top of `baseCommit`. Touches no ref. */
async function buildCommit(request: LandRequest, startedAt: number): Promise<string> {
  const { repoRoot, baseCommit, patchPath, message, indexFile } = request;
  clearStaleIndexLock(indexFile, startedAt);
  const tree = await buildTree(repoRoot, baseCommit, patchPath, indexFile);
  const { stdout } = await git(repoRoot, ['commit-tree', tree, '-p', baseCommit, '-m', message]);
  const commit = stdout.trim();
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProtocolError('agent_error', 'git did not return a commit for the reviewed diff', commit);
  }
  return commit;
}

/** Applies the patch onto `baseCommit` in a private index and returns the
 *  resulting tree. Shared by the real land and by `expectedTree`'s pin, so the
 *  two can never compute the tree two different ways. */
async function buildTree(repoRoot: string, baseCommit: string, patchPath: string, indexFile: string): Promise<string> {
  const env = { GIT_INDEX_FILE: indexFile };
  await git(repoRoot, ['read-tree', baseCommit], { env });
  await applyPatch(repoRoot, patchPath, env);
  const { stdout } = await git(repoRoot, ['write-tree'], { env });
  return stdout.trim();
}

/**
 * The tree this session's land would build right now, computed without
 * touching any ref or the operator's index. Called BEFORE `landDiff`, so the
 * result can be pinned to the record ahead of the one write nvime makes —
 * `landedAlready` then has something to compare a candidate commit against
 * that could only have come from this session's own diff.
 */
export async function expectedTree(request: {
  repoRoot: string;
  baseCommit: string;
  patchPath: string;
  indexFile: string;
}): Promise<string> {
  const { repoRoot, baseCommit, patchPath, indexFile } = request;
  try {
    return await buildTree(repoRoot, baseCommit, patchPath, indexFile);
  } finally {
    rmSync(indexFile, { force: true });
    rmSync(lockOf(indexFile), { force: true });
  }
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
 * The last step, and the only one the operator can see.
 *
 * `git merge` moves whatever HEAD points at — NOT `baseBranch`. So HEAD itself
 * is re-read under the run's claim, and both halves of it must still hold: the
 * branch it is ON, and the commit it is AT. Re-reading only the base ref would
 * let a checkout made since the precondition check (a second branch at the same
 * tip, a `git checkout --detach`) fast-forward the reviewed change onto the
 * operator's other ref and rewrite their working tree.
 */
async function fastForward(
  repoRoot: string,
  branch: string,
  baseBranch: string,
  baseCommit: string,
  commit: string,
): Promise<void> {
  const leave = `the reviewed change is on ${branch}; merge it yourself when you have looked at what landed`;
  const head = await readHead(repoRoot);
  if (head.branch !== baseBranch) {
    throw new ProtocolError(
      'agent_error',
      `this checkout left ${baseBranch} while the merge was being prepared`,
      `it is on ${where(head)}; ${leave}`,
    );
  }
  if (head.commit !== baseCommit) {
    throw new ProtocolError('agent_error', `${baseBranch} moved while the merge was being prepared`, leave);
  }
  await git(repoRoot, ['merge', '--ff-only', branch]);
  const landed = await readHead(repoRoot);
  if (landed.branch !== baseBranch || landed.commit !== commit) {
    throw new ProtocolError(
      'agent_error',
      `${baseBranch} is not at the merged commit`,
      `expected ${commit.slice(0, 8)} on ${baseBranch}, found ${where(landed)}`,
    );
  }
}

/** Rollback state, so a failure can say what it left behind rather than guess. */
interface Rollback {
  ok: boolean;
  detail: string;
}

interface RollbackRequest {
  repoRoot: string;
  ref: string;
  /** Where this attempt created `ref`, or null when it never got that far. */
  commit: string | null;
  baseBranch: string;
  baseCommit: string;
  /** The repository as this attempt found it. The rollback is proved against it. */
  before: RepoState;
}

/**
 * Undoes whatever the failed attempt managed to do, then PROVES it against the
 * state this attempt started from: the base branch is back where it was, HEAD
 * is on the same ref at the same commit, and the tracked changes are the ones
 * that were already there.
 *
 * HEAD is checked because the base ref alone cannot see the worst case — a
 * merge that fast-forwarded some OTHER ref leaves `baseBranch` untouched and a
 * `git status` that is clean relative to the new HEAD. And the comparison is
 * against `before` rather than against "clean" so a tree the operator had
 * already edited is not reported under the loudest alarm this design has.
 */
async function rollback(request: RollbackRequest): Promise<Rollback> {
  const { repoRoot, ref, commit, baseBranch, baseCommit, before } = request;
  try {
    // Compare-and-delete: only the ref this attempt created, and only while it
    // still points where this attempt put it.
    if (commit !== null) await deleteIfOurs(repoRoot, ref, commit);
    const base = await resolveRef(repoRoot, baseBranch);
    if (base !== baseCommit) {
      return { ok: false, detail: `${baseBranch} is at ${short(base)}, not the base ${short(baseCommit)}` };
    }
    const head = await readHead(repoRoot);
    if (head.branch !== before.head.branch || head.commit !== before.head.commit) {
      return { ok: false, detail: `HEAD is ${where(head)}, not ${where(before.head)} where this attempt found it` };
    }
    const dirty = await trackedChanges(repoRoot);
    if (!sameLines(dirty, before.dirty)) {
      const now = dirty.length === 0 ? 'nothing' : dirty.slice(0, 5).join(', ');
      return { ok: false, detail: `tracked changes are not what they were: now ${now}, was ${before.dirty.length}` };
    }
    return { ok: true, detail: 'the repository is exactly as it was' };
  } catch (cause) {
    return { ok: false, detail: `the rollback check itself failed: ${detailOf(cause)}` };
  }
}

function sameLines(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && [...a].sort().join('\n') === [...b].sort().join('\n');
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

/** Where a HEAD is, in one phrase: the ref it is on and the commit it is at. */
function where(head: RepoHead): string {
  const on = head.branch === null ? 'a detached HEAD' : head.branch;
  return `${on} at ${short(head.commit)}`;
}
