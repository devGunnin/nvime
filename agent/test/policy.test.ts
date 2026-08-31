import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { classifyTool, isWithin, realPathOf } from '../src/policy.js';

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
