import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { clearCapture, type BigSession } from '../src/bigstore.js';
import { DEFAULT_DIFFICULTY } from '../src/gate.js';
import {
  branchNameFor,
  checkMerge,
  expectedTree,
  holderMessage,
  landDiff,
  type MergeRefusalCode,
} from '../src/merge.js';
import { ProtocolError } from '../src/protocol.js';
import type { TriageBlock } from '../src/triage.js';
import { parseUnifiedDiff } from '../src/unidiff.js';
import { configureGitIdentity } from './fixtures/git-identity.js';

let root = '';
let repo = '';
/** HEAD as the build recorded it, read before any test moves the branch. */
let baseCommit = '';

function run(dir: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim();
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-merge-'));
  repo = join(root, 'repo');
  execFileSync('git', ['init', '-q', '-b', 'main', repo]);
  configureGitIdentity(repo);
  writeFileSync(join(repo, 'tool.py'), 'def main():\n    print("hi")\n');
  run(repo, 'add', '-A');
  run(repo, 'commit', '-qm', 'initial');
  baseCommit = run(repo, 'rev-parse', 'HEAD');
  patchSeq = 0;
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** The diff the review cleared: one line of tool.py, rewritten. */
function patch(): string {
  return [
    'diff --git a/tool.py b/tool.py',
    'index 1111111..2222222 100644',
    '--- a/tool.py',
    '+++ b/tool.py',
    '@@ -1,2 +1,2 @@',
    ' def main():',
    '-    print("hi")',
    '+    print("v1")',
    '',
  ].join('\n');
}

let patchSeq = 0;

/** Each patch gets its own file: two of them in one call would clobber. */
function patchFile(text = patch()): string {
  patchSeq += 1;
  const path = join(root, `diff-${patchSeq}.patch`);
  writeFileSync(path, text);
  return path;
}

function landRequest(overrides: Partial<Parameters<typeof landDiff>[0]> = {}): Parameters<typeof landDiff>[0] {
  return {
    repoRoot: repo,
    branch: 'nvime/big/version-flag',
    baseBranch: 'main',
    baseCommit: run(repo, 'rev-parse', 'HEAD'),
    patchPath: patchFile(),
    message: 'add a version flag',
    indexFile: join(root, 'merge-index'),
    ...overrides,
  };
}

function block(overrides: Partial<TriageBlock> = {}): TriageBlock {
  return {
    id: 'b1',
    title: 'the change',
    files: ['tool.py'],
    hunkIds: ['h1'],
    substantial: true,
    rationale: '',
    state: 'resolved',
    reopened: false,
    signatures: ['s1'],
    rounds: [],
    ...overrides,
  };
}

function session(overrides: Partial<BigSession> = {}): BigSession {
  const now = Date.now();
  return {
    version: 1,
    id: 'abc123',
    repoRoot: repo,
    title: 'add a version flag',
    state: 'reviewing',
    difficulty: DEFAULT_DIFFICULTY,
    createdAt: now,
    updatedAt: now,
    transitions: [],
    conversation: [],
    spec: null,
    approvedAt: now,
    intakeSessionId: null,
    buildSessionId: null,
    gradeSessionId: null,
    base: { commit: baseCommit, branch: 'main' },
    worktree: null,
    runner: null,
    merge: null,
    landAttempt: null,
    diffId: 'd1',
    diffCapturedAt: now,
    diffBytes: 1,
    blocks: [block()],
    ...overrides,
  };
}

async function codes(overrides: Partial<BigSession> = {}, factOverrides = {}): Promise<MergeRefusalCode[]> {
  const refusals = await checkMerge(session(overrides), {
    diff: parseUnifiedDiff(patch()),
    counts: { total: 1, open: 0, substantial: 1, defended: 1 },
    heldBy: null,
    ...factOverrides,
  });
  return refusals.map((refusal) => refusal.code);
}

describe('branchNameFor', () => {
  it('reads as the change it holds', () => {
    assert.equal(branchNameFor('Connection-pool backoff', 'x1'), 'nvime/big/connection-pool-backoff');
  });

  it('survives a title made entirely of punctuation', () => {
    assert.equal(branchNameFor('!!! ???', 'x1'), 'nvime/big/x1');
  });

  it('does not end a ref in a dash, which git rejects', () => {
    const name = branchNameFor('a'.repeat(38) + ' and then some more words', 'x1');
    assert.ok(!name.endsWith('-'), name);
    assert.ok(name.length <= 'nvime/big/'.length + 40);
  });
});

describe('merge preconditions', () => {
  it('lets a finished review through', async () => {
    assert.deepEqual(await codes(), []);
  });

  it('refuses while any thread is open', async () => {
    assert.deepEqual(await codes({}, { counts: { total: 2, open: 1, substantial: 2, defended: 1 } }), [
      'threads-open',
    ]);
  });

  it('refuses a change that is not finished being reviewed', async () => {
    assert.deepEqual(await codes({ state: 'building' }), ['not-reviewing']);
    assert.deepEqual(await codes({ state: 'triaging' }), ['not-reviewing']);
    assert.deepEqual(await codes({ state: 'merged' }), ['already-merged']);
  });

  it('refuses a diff that is not the one the threads describe', async () => {
    assert.deepEqual(await codes({}, { diff: null }), ['no-diff']);
  });

  it('refuses a binary change, naming the files whose bytes the diff does not carry', async () => {
    const binary = parseUnifiedDiff(
      [
        'diff --git a/logo.png b/logo.png',
        'index 1111111..2222222 100644',
        'Binary files a/logo.png and b/logo.png differ',
        '',
      ].join('\n'),
    );
    const refusals = await checkMerge(session(), {
      diff: binary,
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['binary-change']);
    // A build's own output is the usual cause, so the reader has to be told
    // WHICH file to gitignore or ask the build to drop.
    assert.match(refusals[0]?.message ?? '', /logo\.png/);
  });

  it('refuses when another editor is driving the change', async () => {
    const holder = { detached: false, what: 'build' };
    assert.deepEqual(await codes({}, { heldBy: holder }), ['held-elsewhere']);
    assert.match(holderMessage(holder), /another editor/);
  });

  it('names a detached runner as this change still running, not as another editor', async () => {
    const holder = { detached: true, what: 'rebase' };
    assert.deepEqual(await codes({}, { heldBy: holder }), ['held-elsewhere']);
    const message = holderMessage(holder);
    assert.match(message, /outside the editor/);
    assert.match(message, /rebase/);
    assert.doesNotMatch(message, /another editor/, 'their own rebase is not somebody else');
  });

  it('refuses a change built from a detached HEAD, which names no branch', async () => {
    assert.deepEqual(await codes({ base: { commit: baseCommit, branch: null } }), [
      'no-base-branch',
    ]);
  });

  it('refuses when the base branch moved since the build started', async () => {
    writeFileSync(join(repo, 'other.txt'), 'someone else\n');
    run(repo, 'add', '-A');
    run(repo, 'commit', '-qm', 'meanwhile');
    assert.deepEqual(await codes(), ['base-moved']);
  });

  it('refuses when the base branch is gone', async () => {
    run(repo, 'checkout', '-q', '-b', 'side');
    run(repo, 'branch', '-q', '-D', 'main');
    assert.deepEqual(await codes(), ['not-on-base', 'base-gone']);
  });

  it('refuses when the reader is not on the branch the change would land in', async () => {
    run(repo, 'checkout', '-q', '-b', 'side');
    assert.deepEqual(await codes(), ['not-on-base']);
  });

  it('refuses on tracked changes, and ignores untracked build output', async () => {
    writeFileSync(join(repo, 'untracked.log'), 'noise\n');
    assert.deepEqual(await codes(), [], 'untracked files are not a reason to block a merge');
    writeFileSync(join(repo, 'tool.py'), 'def main():\n    print("mine")\n');
    assert.deepEqual(await codes(), ['dirty-tree']);
  });

  it('reports every reason at once rather than one per attempt', async () => {
    run(repo, 'checkout', '-q', '-b', 'side');
    const found = await codes({ state: 'building' }, { counts: { total: 2, open: 2, substantial: 2, defended: 0 } });
    assert.deepEqual(found.sort(), ['not-on-base', 'not-reviewing', 'threads-open']);
  });
});

describe('landing the reviewed diff', () => {
  it('creates the branch, commits the diff, and fast-forwards the base into it', async () => {
    const base = run(repo, 'rev-parse', 'HEAD');
    const landed = await landDiff(landRequest());

    assert.equal(run(repo, 'rev-parse', 'main'), landed.commit);
    assert.equal(run(repo, 'rev-parse', landed.branch), landed.commit);
    assert.equal(run(repo, 'rev-parse', `${landed.commit}^`), base, 'the commit sits directly on the base');
    assert.equal(run(repo, 'log', '-1', '--format=%s'), 'add a version flag');
    assert.equal(readFileSync(join(repo, 'tool.py'), 'utf8'), 'def main():\n    print("v1")\n');
    assert.equal(run(repo, 'status', '--porcelain'), '', 'the working tree is clean afterwards');
  });

  it('leaves no trace of the private index in the repository', async () => {
    const indexFile = join(root, 'merge-index');
    const before = readFileSync(join(repo, '.git', 'index'));
    await landDiff(landRequest({ indexFile }));
    assert.equal(existsSync(indexFile), false, 'the scratch index is removed');
    // The operator's own index was never the one written through.
    assert.ok(before.length > 0);
  });

  it('writes the commit with the operator git identity, not an agent one', async () => {
    const landed = await landDiff(landRequest());
    assert.equal(run(repo, 'log', '-1', '--format=%an', landed.commit), 'nvime tests');
    assert.equal(run(repo, 'log', '-1', '--format=%b', landed.commit), '', 'no attribution trailer');
  });

  it('refuses with a clear message, and writes nothing, when the operator repo has no git identity', async () => {
    run(repo, 'config', '--unset', 'user.name');
    run(repo, 'config', '--unset', 'user.email');
    const before = snapshot();
    await withoutAmbientGitIdentity(async () => {
      await assert.rejects(
        () => landDiff(landRequest()),
        (error: unknown) => {
          assert.ok(error instanceof ProtocolError);
          assert.match(error.message, /no git identity configured/);
          assert.match(error.detail ?? '', /git config user\.name/);
          return true;
        },
      );
    });
    assert.deepEqual(snapshot(), before, 'nothing was written');
  });

  it('refuses to overwrite a branch that already exists', async () => {
    run(repo, 'branch', 'nvime/big/version-flag');
    const before = snapshot();
    await assert.rejects(() => landDiff(landRequest()), ProtocolError);
    assert.deepEqual(snapshot(), before, 'and changes nothing on the way out');
  });

  it('rolls the repository back byte for byte when the diff no longer applies', async () => {
    const before = snapshot();
    const conflicting = patch().replace('    print("hi")', '    print("something else entirely")');
    await assert.rejects(
      () => landDiff(landRequest({ patchPath: patchFile(conflicting) })),
      (error: unknown) => {
        assert.ok(error instanceof ProtocolError);
        assert.match(error.message, /no longer applies/);
        assert.match(error.detail ?? '', /rolled back: the repository is exactly as it was/);
        return true;
      },
    );
    assert.deepEqual(snapshot(), before);
    assert.equal(run(repo, 'branch', '--list', 'nvime/big/version-flag'), '', 'no half-made branch is left behind');
  });

  it('leaves the repository byte-identical when it stops after the apply, before the ref', async () => {
    // The read-tree, the apply, the tree and the commit all succeed; creating
    // the ref then fails, because git will not accept this name. Everything up
    // to that point happened in the private index, so there is nothing in the
    // repository to undo — which is the property the ordering exists to give.
    const before = snapshot();
    await assert.rejects(() => landDiff(landRequest({ branch: 'nvime/big/not..a.ref' })), ProtocolError);
    assert.deepEqual(snapshot(), before);
    assert.equal(existsSync(join(root, 'merge-index')), false, 'and the scratch index is gone');
  });

  it('leaves the branch for the reader when the base moves while the commit is being built', async () => {
    // The patch is built against the recorded base; the branch really does move
    // underneath, which is the race `--ff-only` and the re-check exist for.
    const request = landRequest();
    writeFileSync(join(repo, 'other.txt'), 'someone else\n');
    run(repo, 'add', '-A');
    run(repo, 'commit', '-qm', 'meanwhile');
    const moved = run(repo, 'rev-parse', 'main');

    await assert.rejects(
      () => landDiff(request),
      (error: unknown) => {
        assert.ok(error instanceof ProtocolError);
        assert.match(error.message, /main moved while the merge was being prepared/);
        return true;
      },
    );
    assert.equal(run(repo, 'rev-parse', 'main'), moved, 'their branch is untouched');
    assert.equal(run(repo, 'status', '--porcelain'), '', 'and so is their tree');
  });

  it('refuses when the checkout left the base branch for another one at the same commit', async () => {
    // `git merge` moves whatever HEAD points at, not `baseBranch`. A second
    // branch at the same tip is the ordinary way to be off the base while every
    // ref this merge reads still says exactly what it said at the check.
    const request = landRequest();
    run(repo, 'checkout', '-q', '-b', 'side');
    const before = snapshot();

    await assert.rejects(
      () => landDiff(request),
      (error: unknown) => {
        assert.ok(error instanceof ProtocolError);
        assert.match(error.message, /left main while the merge was being prepared/);
        assert.match(error.detail ?? '', /rolled back: the repository is exactly as it was/);
        return true;
      },
    );
    assert.deepEqual(snapshot(), before, 'their other branch, their HEAD and their tree are untouched');
  });

  it('refuses on a detached HEAD sitting at the base commit', async () => {
    const request = landRequest();
    run(repo, 'checkout', '-q', '--detach');
    const before = snapshot();

    await assert.rejects(
      () => landDiff(request),
      (error: unknown) => {
        assert.ok(error instanceof ProtocolError);
        assert.match(error.detail ?? '', /a detached HEAD/);
        return true;
      },
    );
    assert.deepEqual(snapshot(), before);
  });

  it('does not report a tree the operator had already edited as a failed rollback', async () => {
    // The apply happens in the private index and succeeds; `merge --ff-only`
    // then refuses because their edit is in the way. Nothing was rolled back
    // because nothing happened — and their own edit must not be raised under
    // the one alarm that is supposed to mean nvime broke something.
    writeFileSync(join(repo, 'tool.py'), 'def main():\n    print("mine, half-finished")\n');
    const before = snapshot();
    await assert.rejects(
      () => landDiff(landRequest()),
      (error: unknown) => {
        assert.ok(error instanceof ProtocolError);
        assert.equal(error.code, 'bad_request', 'a verified rollback is not an agent error');
        assert.match(error.detail ?? '', /rolled back: the repository is exactly as it was/);
        assert.ok(!(error.detail ?? '').includes('ROLLBACK:'), error.detail ?? '');
        return true;
      },
    );
    assert.deepEqual(snapshot(), before, 'and their half-finished edit is still there');
  });
});

describe('the private index of a merge', () => {
  it('clears the lock a killed `git apply` leaves behind, instead of wedging every later merge', async () => {
    // What a SIGKILL of the `apply --cached` child leaves: git creates
    // `<index>.lock` beside the index and only removes it on a clean exit.
    const indexFile = join(root, 'merge-index');
    writeFileSync(`${indexFile}.lock`, '');
    const landed = await landDiff(landRequest({ indexFile }));

    assert.equal(run(repo, 'rev-parse', 'main'), landed.commit, 'the merge still lands');
    assert.equal(existsSync(`${indexFile}.lock`), false, 'and leaves no lock of its own behind');
    assert.equal(existsSync(indexFile), false);
  });

  it('leaves no lock behind when the land fails either', async () => {
    const indexFile = join(root, 'merge-index');
    const conflicting = patch().replace('    print("hi")', '    print("something else entirely")');
    await assert.rejects(() => landDiff(landRequest({ indexFile, patchPath: patchFile(conflicting) })), ProtocolError);
    assert.equal(existsSync(`${indexFile}.lock`), false);
    assert.equal(existsSync(indexFile), false);
  });

  it('refuses an index path inside the repository, which the lock cleanup would reach into', async () => {
    await assert.rejects(
      () => landDiff(landRequest({ indexFile: join(repo, '.git', 'index') })),
      (error: unknown) => error instanceof ProtocolError && /outside the repository/.test(error.message),
    );
    assert.equal(run(repo, 'rev-parse', 'main'), baseCommit, 'and lands nothing');
  });
});

describe('a merge whose record write did not survive', () => {
  /** The branch a real land for `session()` would have created. */
  const OWN_BRANCH = branchNameFor('add a version flag', 'abc123');

  /** The tree `session()`'s own diff builds at `baseCommit` — the same value
   *  `BigService.merge` pins to the record before landing. */
  async function ownTree(): Promise<string> {
    return expectedTree({ repoRoot: repo, baseCommit, patchPath: patchFile(), indexFile: join(root, 'pin-index') });
  }

  it('recognises its own landed change instead of calling it a base that moved', async () => {
    const tree = await ownTree();
    const landed = await landDiff(landRequest({ branch: OWN_BRANCH }));
    // The record the merge would have written is exactly what is missing here:
    // the session still says `reviewing` on the base the build started from,
    // but what it pinned before landing — the branch and the tree — survived.
    const stale = session({
      base: { commit: baseCommit, branch: 'main' },
      landAttempt: { branch: OWN_BRANCH, tree },
    });
    const refusals = await checkMerge(stale, {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['merged-elsewhere']);
    assert.match(refusals[0]?.message ?? '', new RegExp(landed.commit.slice(0, 8)));
  });

  it('stops pointing at a landed-but-unrecorded commit once the session is revised', async () => {
    // The reported bug: the record write after landing THIS branch failed, so
    // the session still says `reviewing` with the old land attempt pinned.
    // The reader then revises the change (a new build capture), which must
    // disown that pin — otherwise the REVISED session is told it "already
    // landed" as the stale, pre-revision commit. `clearCapture` itself no
    // longer nulls the pin (a reconcile-holding reviewing record must keep
    // it, P5 finding 3) — the caller genuinely re-capturing, here standing in
    // for big.ts's `#captureAndTriage`, disowns it explicitly.
    const tree = await ownTree();
    await landDiff(landRequest({ branch: OWN_BRANCH }));
    const revised = session({
      base: { commit: baseCommit, branch: 'main' },
      landAttempt: { branch: OWN_BRANCH, tree },
    });
    clearCapture(revised);
    revised.landAttempt = null;
    const refusals = await checkMerge(revised, {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['base-moved']);
  });

  it('still calls somebody else\'s commit a base that moved', async () => {
    writeFileSync(join(repo, 'other.txt'), 'someone else\n');
    run(repo, 'add', '-A');
    run(repo, 'commit', '-qm', 'meanwhile');
    const refusals = await checkMerge(session(), {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['base-moved']);
  });

  it('does not mistake an older session\'s branch of the same name for this change', async () => {
    // Same slug, landed long ago on a different base: it IS an ancestor of
    // main, so only the parent check tells the two apart.
    run(repo, 'checkout', '-q', '-b', OWN_BRANCH);
    writeFileSync(join(repo, 'unrelated.txt'), 'an older change\n');
    run(repo, 'add', '-A');
    run(repo, 'commit', '-qm', 'an older change of the same name');
    writeFileSync(join(repo, 'unrelated.txt'), 'and again\n');
    run(repo, 'commit', '-qam', 'so it does not sit on the base either');
    run(repo, 'checkout', '-q', 'main');
    run(repo, 'merge', '-q', '--ff-only', OWN_BRANCH);

    const refusals = await checkMerge(session(), {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['base-moved']);
  });

  it('does not claim a sibling session\'s landing of the same title, even one commit directly on the base', async () => {
    // The adjacent case the two-commit test above stops short of: ONE commit,
    // sitting directly on the base, so name-and-parent alone would match it —
    // this is the ordinary shape of a second session opened with the same
    // title. This session never pinned a land attempt of its own, so nothing
    // titled the same can ever be claimed as its landing.
    run(repo, 'checkout', '-q', '-b', OWN_BRANCH);
    writeFileSync(join(repo, 'tool.py'), 'def main():\n    print("a sibling session landed this")\n');
    run(repo, 'commit', '-qam', 'a sibling session, same title, same base');
    run(repo, 'checkout', '-q', 'main');
    run(repo, 'merge', '-q', '--ff-only', OWN_BRANCH);

    const refusals = await checkMerge(session(), {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['base-moved']);
  });

  it('does not claim a same-named, same-parent branch that holds different content', async () => {
    // This session DID pin a land attempt — the name check alone would pass —
    // but the branch that exists carries different content. The tree check
    // must still refuse it rather than call someone else's change its own.
    const tree = await ownTree();
    run(repo, 'checkout', '-q', '-b', OWN_BRANCH);
    writeFileSync(join(repo, 'tool.py'), 'def main():\n    print("not the reviewed change")\n');
    run(repo, 'commit', '-qam', 'a different change under the same branch name');
    run(repo, 'checkout', '-q', 'main');
    run(repo, 'merge', '-q', '--ff-only', OWN_BRANCH);

    const stale = session({
      base: { commit: baseCommit, branch: 'main' },
      landAttempt: { branch: OWN_BRANCH, tree },
    });
    const refusals = await checkMerge(stale, {
      diff: parseUnifiedDiff(patch()),
      counts: { total: 1, open: 0, substantial: 1, defended: 1 },
      heldBy: null,
    });
    assert.deepEqual(refusals.map((refusal) => refusal.code), ['base-moved']);
  });
});

describe('landing the reviewed diff, continued', () => {
  it('resolves a patch whose own context has changed, through the 3-way fallback', async () => {
    // The reviewed change rewrites line 2. The base has since rewritten line 5,
    // which is inside the patch's context — plain `git apply` refuses on it, and
    // `--3way` merges the two from the preimage blob the patch names.
    const notes = (edits: Record<number, string>): string => {
      const lines = Array.from({ length: 20 }, (_, index) => `l${index + 1}`);
      for (const [at, text] of Object.entries(edits)) lines[Number(at)] = text;
      return lines.join('\n') + '\n';
    };
    writeFileSync(join(repo, 'notes.txt'), notes({}));
    run(repo, 'add', '-A');
    run(repo, 'commit', '-qm', 'notes');
    const captured = run(repo, 'rev-parse', 'HEAD');

    // Committed, then rewound: `--3way` merges blobs, so both sides of the patch
    // must be in the object database — as they are for a real build's capture.
    writeFileSync(join(repo, 'notes.txt'), notes({ 1: 'the reviewed change' }));
    run(repo, 'commit', '-qam', 'the reviewed change');
    // `run` trims, and a patch with no trailing newline does not apply.
    const drift = run(repo, 'diff', '--no-ext-diff', captured, 'HEAD') + '\n';
    run(repo, 'reset', '-q', '--hard', captured);

    writeFileSync(join(repo, 'notes.txt'), notes({ 4: 'someone else, in the context' }));
    run(repo, 'commit', '-qam', 'meanwhile, inside the context');
    const base = run(repo, 'rev-parse', 'HEAD');

    const landed = await landDiff(landRequest({ patchPath: patchFile(drift), baseCommit: base }));
    assert.equal(run(repo, 'rev-parse', 'main'), landed.commit);
    assert.equal(
      readFileSync(join(repo, 'notes.txt'), 'utf8'),
      notes({ 1: 'the reviewed change', 4: 'someone else, in the context' }),
      'both changes survive the merge',
    );
  });
});

/** Everything about the repository a merge must not change when it fails. */
function snapshot(): Record<string, string> {
  return {
    head: run(repo, 'rev-parse', 'HEAD'),
    main: run(repo, 'rev-parse', 'main'),
    status: run(repo, 'status', '--porcelain'),
    tool: readFileSync(join(repo, 'tool.py'), 'utf8'),
    refs: run(repo, 'show-ref'),
  };
}

/**
 * Runs `body` with no git identity reachable from anywhere but the repo's own
 * local config — the same isolation CI runners give every command for free,
 * reproduced here so "the operator has none configured" is deterministic on a
 * dev machine that has a global one. Restores the real environment after.
 */
async function withoutAmbientGitIdentity(body: () => Promise<void>): Promise<void> {
  const emptyHome = mkdtempSync(join(tmpdir(), 'nvime-noident-home-'));
  const saved = { HOME: process.env.HOME, GIT_CONFIG_GLOBAL: process.env.GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM: process.env.GIT_CONFIG_SYSTEM };
  process.env.HOME = emptyHome;
  process.env.GIT_CONFIG_GLOBAL = '/dev/null';
  process.env.GIT_CONFIG_SYSTEM = '/dev/null';
  try {
    await body();
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(emptyHome, { recursive: true, force: true });
  }
}
