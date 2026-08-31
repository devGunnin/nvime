import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { classifyBuildTool, classifyTool, isWithin, realPathOf } from '../src/policy.js';

describe('policy: the project-root boundary', () => {
  let dir = '';
  let root = '';
  let outside = '';

  beforeEach(() => {
    // The temp dir itself can sit behind a symlink (/var -> /private/var), so
    // every expectation is written against the resolved path, like the policy.
    dir = realPathOf(mkdtempSync(join(tmpdir(), 'nvime-policy-')));
    root = join(dir, 'project');
    outside = join(dir, 'elsewhere');
    mkdirSync(join(root, 'src'), { recursive: true });
    mkdirSync(outside, { recursive: true });
    writeFileSync(join(root, 'src', 'a.ts'), 'export const a = 1;\n');
    writeFileSync(join(outside, 'secret.txt'), 'shh\n');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  const edit = (path: string) => classifyTool('Edit', { file_path: path }, root);

  it('allows a write to an existing file under the root', () => {
    assert.deepEqual(edit(join(root, 'src', 'a.ts')), {
      kind: 'allow',
      path: join(root, 'src', 'a.ts'),
    });
  });

  it('allows a write that creates a file that does not exist yet', () => {
    const target = join(root, 'src', 'nested', 'new.ts');
    assert.deepEqual(edit(target), { kind: 'allow', path: target });
  });

  it('asks before a write outside the root', () => {
    const decision = edit(join(outside, 'secret.txt'));
    assert.equal(decision.kind, 'ask');
    assert.match(decision.kind === 'ask' ? decision.reason : '', /outside the project root/);
  });

  it('asks when `..` walks out of the root', () => {
    const decision = edit(join(root, 'src', '..', '..', 'elsewhere', 'secret.txt'));
    assert.equal(decision.kind, 'ask');
  });

  it('asks when a symlink inside the root points out of it', () => {
    symlinkSync(outside, join(root, 'escape'));
    const decision = edit(join(root, 'escape', 'secret.txt'));
    assert.equal(decision.kind, 'ask', 'a resolved symlink target is what counts, not the written path');
  });

  it('asks when a symlinked directory would receive a brand new file', () => {
    symlinkSync(outside, join(root, 'escape'));
    const decision = edit(join(root, 'escape', 'made-up.txt'));
    assert.equal(decision.kind, 'ask', 'a path with no existing leaf still resolves its existing prefix');
  });

  it('asks when `..` follows a symlink that points out of the root', () => {
    // The reviewer's probe, verbatim: `path.resolve` collapses `vendor/..`
    // lexically to `<root>/src`, but the kernel climbs out of the link target.
    symlinkSync(outside, join(root, 'src', 'vendor'));
    const decision = edit(`${root}/src/vendor/../pwned.txt`);
    assert.equal(decision.kind, 'ask', 'a `..` after a symlink escapes the root');
    assert.equal(decision.path, join(dir, 'pwned.txt'), 'and the path it names is the real one');
  });

  it('asks for the same shape one level up, where `..` lands beside the root', () => {
    const deep = join(outside, 'deep');
    mkdirSync(deep, { recursive: true });
    symlinkSync(deep, join(root, 'link'));
    const decision = edit(`${root}/link/../pwned.txt`);
    assert.equal(decision.kind, 'ask');
    assert.equal(decision.path, join(outside, 'pwned.txt'));
  });

  it('asks when a chain of symlinks is walked back out of with `..`', () => {
    mkdirSync(join(outside, 'inner'), { recursive: true });
    symlinkSync(outside, join(root, 'a'));
    symlinkSync(join(outside, 'inner'), join(outside, 'b'));
    const decision = edit(`${root}/a/b/../../pwned.txt`);
    assert.equal(decision.kind, 'ask', 'each link is followed before the next `..` applies');
    assert.equal(decision.path, join(dir, 'pwned.txt'));
  });

  it('asks about a symlink whose target does not exist yet, outside the root', () => {
    // One committed file in a repo: `deploy -> ~/.bashrc.d/x.sh`. The kernel
    // follows it and creates the target; treating it as "absent" allowed the
    // write with no approval at all.
    const landing = join(outside, 'not-created-yet.sh');
    symlinkSync(landing, join(root, 'deploy'));
    const decision = edit(join(root, 'deploy'));
    assert.equal(decision.kind, 'ask', 'a dangling link out of the root is still a write out of the root');
    assert.equal(decision.path, landing, 'and the ask names where the bytes would land');
  });

  it('asks about a dangling symlink nested deep in the path', () => {
    mkdirSync(join(root, 'a', 'b'), { recursive: true });
    symlinkSync(join(outside, 'gone'), join(root, 'a', 'b', 'link'));
    const decision = edit(join(root, 'a', 'b', 'link', 'x.txt'));
    assert.equal(decision.kind, 'ask');
    assert.equal(decision.path, join(outside, 'gone', 'x.txt'));
  });

  it('follows a dangling symlink written as a relative target', () => {
    symlinkSync('../elsewhere/new.txt', join(root, 'rel'));
    const decision = edit(join(root, 'rel'));
    assert.equal(decision.kind, 'ask');
    assert.equal(decision.path, join(outside, 'new.txt'), 'link text is resolved from the link, not the cwd');
  });

  it('walks a chain of links to the file that does not exist at the end of it', () => {
    symlinkSync(join(root, 'hop2'), join(root, 'hop1'));
    symlinkSync(join(outside, 'final.txt'), join(root, 'hop2'));
    const decision = edit(join(root, 'hop1'));
    assert.equal(decision.kind, 'ask');
    assert.equal(decision.path, join(outside, 'final.txt'));
  });

  it('still allows a dangling symlink that points back inside the root', () => {
    const target = join(root, 'src', 'todo.ts');
    symlinkSync(target, join(root, 'later'));
    assert.deepEqual(edit(join(root, 'later')), { kind: 'allow', path: target });
  });

  it('still allows a component that is genuinely absent rather than a link', () => {
    const target = join(root, 'src', 'brand', 'new.ts');
    assert.deepEqual(edit(target), { kind: 'allow', path: target });
  });

  it('denies a path the kernel cannot resolve instead of throwing', () => {
    symlinkSync(join(root, 'b'), join(root, 'a'));
    symlinkSync(join(root, 'a'), join(root, 'b'));
    const decision = edit(join(root, 'a'));
    assert.equal(decision.kind, 'deny', 'one bad path must not take the whole run down');
    assert.match(decision.kind === 'deny' ? decision.reason : '', /could not resolve/);
  });

  it('denies a dangling symlink that resolves back through itself', () => {
    // `a -> b/../a` with `b` missing: every hop raises ENOENT rather than
    // ELOOP, so nothing but nvime's own hop budget ends the walk.
    symlinkSync(`${root}/b/../a`, join(root, 'a'));
    const decision = edit(join(root, 'a'));
    assert.equal(decision.kind, 'deny');
    assert.match(decision.kind === 'deny' ? decision.reason : '', /could not resolve/);
  });

  it('still allows a `..` that stays inside the root', () => {
    const decision = edit(`${root}/src/../src/a.ts`);
    assert.deepEqual(decision, { kind: 'allow', path: join(root, 'src', 'a.ts') });
  });

  it('does not mistake a sibling whose name starts with the root for a child', () => {
    assert.equal(isWithin('/work/proj', '/work/project/file.ts'), false);
    assert.equal(isWithin('/work/proj', '/work/proj/file.ts'), true);
    assert.equal(isWithin('/work/proj', '/work/proj'), true);
  });

  it('denies a mutation that names no path, or a relative one', () => {
    assert.equal(classifyTool('Edit', {}, root).kind, 'deny');
    assert.equal(classifyTool('Write', { file_path: 'src/a.ts' }, root).kind, 'deny');
  });

  it('resolves the notebook tool through its own path key', () => {
    const target = join(root, 'nb.ipynb');
    assert.deepEqual(classifyTool('NotebookEdit', { notebook_path: target }, root), {
      kind: 'allow',
      path: target,
    });
  });
});

describe('policy: tools other than file writes', () => {
  const root = '/work/proj';

  it('allows the read-only tools outright', () => {
    for (const tool of ['Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch']) {
      assert.deepEqual(classifyTool(tool, {}, root), { kind: 'allow' }, tool);
    }
  });

  it('asks before any shell tool, however harmless the command looks', () => {
    const decision = classifyTool('Bash', { command: 'ls' }, root);
    assert.equal(decision.kind, 'ask');
    assert.match(decision.kind === 'ask' ? decision.reason : '', /shell command/);
  });

  it('asks about a tool it has no policy for, rather than letting it through', () => {
    const decision = classifyTool('SomeFutureTool', {}, root);
    assert.equal(decision.kind, 'ask');
  });
});

describe('policy: the big-change build boundary', () => {
  let dir = '';
  let worktree = '';
  let outside = '';

  beforeEach(() => {
    dir = realPathOf(mkdtempSync(join(tmpdir(), 'nvime-build-')));
    worktree = join(dir, 'wt');
    outside = join(dir, 'home');
    mkdirSync(join(worktree, 'src'), { recursive: true });
    mkdirSync(outside, { recursive: true });
    writeFileSync(join(worktree, 'src', 'a.ts'), 'export const a = 1;\n');
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  const write = (path: string) => classifyBuildTool('Write', { file_path: path }, worktree);

  it('lets the build write anywhere inside its own worktree, unattended', () => {
    for (const target of [join(worktree, 'src', 'a.ts'), join(worktree, 'new', 'file.ts')]) {
      assert.deepEqual(write(target), { kind: 'allow', path: target }, target);
    }
  });

  it('runs shell without asking, because a build has to run the tests', () => {
    for (const tool of ['Bash', 'BashOutput', 'KillShell']) {
      assert.deepEqual(classifyBuildTool(tool, { command: 'npm test' }, worktree), { kind: 'allow' }, tool);
    }
  });

  it('denies a write outside the worktree rather than asking a user who may be gone', () => {
    const decision = write(join(outside, '.bashrc'));
    assert.equal(decision.kind, 'deny');
    assert.match(decision.kind === 'deny' ? decision.reason : '', /only write inside its own worktree/);
  });

  it('denies a write through a symlink that leaves the worktree', () => {
    symlinkSync(outside, join(worktree, 'escape'));
    assert.equal(write(join(worktree, 'escape', 'x.txt')).kind, 'deny');
    // Concatenated, not `join`ed: `join` would collapse `..` before the policy
    // ever sees it, which is exactly the bug being guarded against.
    assert.equal(write(`${worktree}/escape/../taken.txt`).kind, 'deny');
  });

  it('denies a relative path and a tool it has no policy for', () => {
    assert.equal(classifyBuildTool('Write', { file_path: 'relative.txt' }, worktree).kind, 'deny');
    assert.equal(classifyBuildTool('Write', {}, worktree).kind, 'deny');
    assert.equal(classifyBuildTool('SomeFutureTool', {}, worktree).kind, 'deny');
  });

  it('never asks: nothing is watching a build that outlives the editor', () => {
    const decisions = [
      classifyBuildTool('Read', {}, worktree),
      classifyBuildTool('Bash', { command: 'rm -rf /' }, worktree),
      write(join(outside, 'x')),
      classifyBuildTool('Unknown', {}, worktree),
    ];
    assert.ok(decisions.every((decision) => decision.kind !== 'ask'));
  });
});
