import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createServer, type Server } from 'node:http';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { CertificationService, parseGitHubRemote } from '../src/certification.js';
import type { SessionView } from '../src/big.js';
import { ManagedPolicyClient } from '../src/managed-policy.js';
import { configureGitIdentity } from './fixtures/git-identity.js';

const POLICY = {
  schema: 'dev.nvime.organization-policy/v1', policyId: 'org:42:policy:7', organizationId: 42,
  revision: 7, gateMode: 'medium', threshold: 70, allowedProviders: ['claude'],
  interactionMode: 'user-choice', updatedAt: '2026-09-02T10:00:00.000Z',
};

let root = '';
let repo = '';
let server: Server | null = null;
let received: Record<string, unknown> | null = null;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-cert-'));
  repo = join(root, 'repo');
  mkdirSync(repo);
  git('init', '-q', '-b', 'main');
  configureGitIdentity(repo);
  writeFileSync(join(repo, 'file.txt'), 'base\n');
  git('add', '-A');
  git('commit', '-qm', 'base');
  writeFileSync(join(repo, 'file.txt'), 'reviewed\n');
  git('commit', '-qam', 'reviewed');
  git('remote', 'add', 'origin', 'git@github.com:devGunnin/nvime.git');
});

afterEach(async () => {
  if (server) await new Promise<void>((resolve, reject) => server?.close((error) => error ? reject(error) : resolve()));
  rmSync(root, { recursive: true, force: true });
  server = null;
  received = null;
});

function git(...args: string[]): string {
  assert(repo !== '', 'repository fixture must be initialized');
  assert(args.length > 0, 'git command must not be empty');
  return execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim();
}

function executable(name: string, body: string): string {
  assert(name.length > 0, 'fixture executable needs a name');
  assert(body.includes('#!/usr/bin/env node'), 'fixture executable must declare its runtime');
  const path = join(root, name);
  writeFileSync(path, body, { mode: 0o700 });
  chmodSync(path, 0o700);
  return path;
}

async function controlPlane(): Promise<string> {
  server = createServer((request, response) => {
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET') return response.end(JSON.stringify(POLICY));
    const chunks: Buffer[] = [];
    request.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    request.on('end', () => {
      received = JSON.parse(Buffer.concat(chunks).toString('utf8')) as Record<string, unknown>;
      response.end(JSON.stringify({ commitSha: git('rev-parse', 'HEAD'), verifiedAt: '2026-09-02T10:05:00.000Z' }));
    });
  });
  await new Promise<void>((resolve, reject) => {
    assert(server !== null, 'control plane must exist before listen');
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address !== null && typeof address === 'object', 'control plane must use TCP');
  assert(address.port > 0, 'control plane must receive a port');
  return `http://127.0.0.1:${address.port}`;
}

function session(): SessionView {
  const head = git('rev-parse', 'HEAD');
  const base = git('rev-parse', 'HEAD^');
  const now = Date.now();
  assert(head !== base, 'review fixture needs distinct base and head commits');
  assert(head.length === 40 && base.length === 40, 'review fixture needs full Git SHAs');
  return {
    version: 1, id: 'review1', repoRoot: repo, title: 'reviewed change', state: 'merged',
    difficulty: 'medium', threshold: 70, policyId: 'org:42:policy:7', createdAt: now, updatedAt: now,
    transitions: [], conversation: [], spec: null, approvedAt: now, intakeSessionId: null,
    buildSessionId: null, gradeSessionId: null, base: { commit: base, branch: 'main' }, worktree: null,
    runner: null, merge: { branch: 'nvime/big/reviewed-change', commit: head, baseBranch: 'main', at: now },
    landAttempt: null, diffId: 'd'.repeat(64), diffCapturedAt: now, diffBytes: 42,
    blocks: [{ id: 'thread1', title: 'behavior', files: ['file.txt'], hunkIds: ['h1'], substantial: true,
      rationale: 'behavior changed', state: 'resolved', reopened: false, signatures: ['s1'],
      rounds: [{ at: now, answer: 'it replaces the base behavior', result: { grade: 92, verdict: 'clear', hint: '', followup: '' } }] }],
    display: 'merged', detached: false, heldElsewhere: false, runnerLive: false, steerable: false,
    worktreeExists: false, hasDiff: true, counts: { total: 1, open: 0, substantial: 1, defended: 1 },
  };
}

function service(base: string): CertificationService {
  const publicKey = Buffer.alloc(44, 7).toString('base64');
  const signature = Buffer.alloc(64, 9).toString('base64');
  const trust = executable('trust.mjs', `#!/usr/bin/env node\nimport fs from 'node:fs';\nif (process.argv[2] === 'keygen') fs.writeFileSync(process.argv[3], 'secret', { mode: 0o600 });\nelse process.stdout.write(JSON.stringify({ signature: '${signature}', publicKey: '${publicKey}' }));\n`);
  const github = executable('github.mjs', `#!/usr/bin/env node\nprocess.stdout.write(process.argv.includes('user') ? '31415' : '27182');\n`);
  return new CertificationService(new ManagedPolicyClient(base), trust, join(root, 'identity'), github);
}

describe('GitHub identity parsing', () => {
  it('accepts the three exact github.com transport forms', () => {
    assert.deepEqual(parseGitHubRemote('https://github.com/acme/repo.git'), { owner: 'acme', name: 'repo' });
    assert.deepEqual(parseGitHubRemote('git@github.com:acme/repo.git'), { owner: 'acme', name: 'repo' });
    assert.deepEqual(parseGitHubRemote('ssh://git@github.com/acme/repo'), { owner: 'acme', name: 'repo' });
  });

  it('rejects lookalike hosts and ambiguous paths', () => {
    assert.throws(() => parseGitHubRemote('https://github.com.evil.test/acme/repo.git'), /github.com/);
    assert.throws(() => parseGitHubRemote('https://github.com/acme/team/repo.git'), /github.com/);
  });
});

describe('managed certification', () => {
  it('builds an administrator-safe public enrollment record', async () => {
    const enrollment = await service(await controlPlane()).enrollment(repo);
    assert.equal(enrollment.reviewerId, 'github:31415');
    assert.deepEqual(enrollment.repositoryIds, [27182]);
    assert.match(enrollment.keyId, /^device:[a-f0-9]{64}$/);
    assert.equal(Buffer.from(enrollment.publicKey, 'base64').length, 44);
  });

  it('signs and submits evidence bound to the reviewed commit and policy', async () => {
    const view = session();
    const result = await service(await controlPlane()).attest(view);
    assert.equal(result.commitSha, view.merge?.commit);
    assert(received !== null, 'control plane must receive the signed envelope');
    const evidence = received.evidence as Record<string, unknown>;
    assert.equal(evidence.policyId, 'org:42:policy:7');
    assert.equal(evidence.reviewerId, 'github:31415');
    assert.equal((evidence.repository as Record<string, unknown>).githubRepositoryId, 27182);
  });

  it('refuses evidence when HEAD moved after review', async () => {
    const view = session();
    writeFileSync(join(repo, 'later.txt'), 'later\n');
    git('add', '-A');
    git('commit', '-qm', 'later');
    const managed = service(await controlPlane());
    await assert.rejects(() => managed.attest(view), /HEAD no longer matches/);
    assert.equal(received, null, 'stale evidence must never reach the control plane');
  });
});
