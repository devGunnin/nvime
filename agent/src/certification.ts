import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import type { SessionView } from './big.js';
import { ManagedPolicyClient, type OrganizationPolicy } from './managed-policy.js';
import { ProtocolError } from './protocol.js';

const run = promisify(execFile);
const SHA = /^[a-f0-9]{40,64}$/;
const SLUG = /^[A-Za-z0-9_.-]+$/;

interface DeviceIdentity { readonly keyId: string; readonly publicKey: string }
interface RepositoryIdentity { readonly githubRepositoryId: number; readonly owner: string; readonly name: string }
interface GateEvidence { readonly threadId: string; readonly grade: number; readonly threshold: number; readonly rounds: number; readonly evidenceDigest: string }
interface ReviewEvidence {
  readonly schema: 'dev.nvime.attestation/v1'; readonly repository: RepositoryIdentity;
  readonly commitSha: string; readonly baseSha: string; readonly diffDigest: string; readonly policyId: string;
  readonly reviewerId: string; readonly deviceKeyId: string; readonly issuedAt: string; readonly expiresAt: string;
  readonly gates: readonly GateEvidence[];
}

export interface EnrollmentRecord {
  readonly keyId: string;
  readonly publicKey: string;
  readonly reviewerId: string;
  readonly organizationId: number;
  readonly repositoryIds: readonly number[];
  readonly revokedAt: null;
}

export class CertificationService {
  readonly #trust: TrustCore;

  constructor(
    private readonly client: ManagedPolicyClient,
    trustExecutable: string,
    identityDirectory: string,
    private readonly githubExecutable: string,
  ) {
    if (!isAbsolute(trustExecutable) || !isAbsolute(identityDirectory)) throw new TypeError('managed trust paths must be absolute');
    if (!githubExecutable.trim()) throw new TypeError('GitHub CLI executable must not be empty');
    this.#trust = new TrustCore(trustExecutable, identityDirectory);
    assert(resolve(identityDirectory) !== resolve(trustExecutable), 'identity directory must differ from trust executable');
    assert(githubExecutable.length <= 4_096, 'GitHub CLI executable path must be bounded');
  }

  policy(): Promise<OrganizationPolicy> {
    return this.client.policy();
  }

  async enrollment(root: string): Promise<EnrollmentRecord> {
    const policy = await this.client.policy();
    const [device, github] = await Promise.all([this.#trust.identity(), inspectGitHub(root, this.githubExecutable)]);
    assert(github.repository.githubRepositoryId > 0, 'GitHub repository ID must be positive');
    assert(/^github:[1-9][0-9]*$/.test(github.reviewerId), 'GitHub reviewer identity must be numeric');
    return {
      keyId: device.keyId,
      publicKey: device.publicKey,
      reviewerId: github.reviewerId,
      organizationId: policy.organizationId,
      repositoryIds: [github.repository.githubRepositoryId],
      revokedAt: null,
    };
  }

  async attest(session: SessionView): Promise<{ commitSha: string; verifiedAt: string }> {
    const policy = await this.client.policy();
    const [device, github] = await Promise.all([
      this.#trust.identity(),
      inspectGitHub(session.repoRoot, this.githubExecutable),
    ]);
    await verifyLandedHead(session);
    const evidence = buildEvidence(session, policy, device, github);
    const signed = await this.#trust.sign(evidence);
    return this.client.submit(signed, evidence.commitSha);
  }
}

class TrustCore {
  readonly #secretPath: string;

  constructor(private readonly executable: string, identityDirectory: string) {
    if (!isAbsolute(executable) || !isAbsolute(identityDirectory)) throw new TypeError('trust core paths must be absolute');
    this.#secretPath = join(resolve(identityDirectory), 'device.ed25519');
    assert(this.#secretPath !== resolve(executable), 'device key path must differ from trust executable');
    assert(this.#secretPath.endsWith('device.ed25519'), 'device key filename must remain stable');
  }

  async identity(): Promise<DeviceIdentity> {
    await this.#ensureIdentity();
    const signed = await this.#signBytes('nvime-key-enrollment');
    const bytes = Buffer.from(signed.publicKey, 'base64');
    if (bytes.length !== 44 || bytes.toString('base64') !== signed.publicKey) throw managedError('trust core returned an invalid public key');
    const keyId = `device:${createHash('sha256').update(bytes).digest('hex')}`;
    assert(keyId.length === 71, 'device key ID must contain SHA-256');
    assert(keyId.startsWith('device:'), 'device key ID must use its namespace');
    return { keyId, publicKey: signed.publicKey };
  }

  async sign(evidence: ReviewEvidence): Promise<{ evidence: ReviewEvidence; signature: string; publicKey: string }> {
    const canonical = canonicalize(evidence);
    const identity = await this.identity();
    if (identity.keyId !== evidence.deviceKeyId) throw managedError('evidence device key does not match this workstation');
    const signed = await this.#signBytes(canonical);
    if (signed.publicKey !== identity.publicKey) throw managedError('trust core returned an inconsistent public key');
    assert(Buffer.from(signed.signature, 'base64').length === 64, 'trust core signature must be Ed25519');
    assert(canonical.length > 100, 'canonical evidence must be non-trivial');
    return { evidence, signature: signed.signature, publicKey: signed.publicKey };
  }

  async #ensureIdentity(): Promise<void> {
    await mkdir(dirname(this.#secretPath), { recursive: true, mode: 0o700 });
    try { await access(this.#secretPath); return; }
    catch (cause) { if ((cause as NodeJS.ErrnoException).code !== 'ENOENT') throw cause; }
    try { await this.#execute(['keygen', this.#secretPath]); }
    catch (cause) {
      try { await access(this.#secretPath); }
      catch { throw cause; }
    }
  }

  async #signBytes(payload: string): Promise<{ signature: string; publicKey: string }> {
    if (!payload || Buffer.byteLength(payload) > 1_000_000) throw new RangeError('signing payload size is invalid');
    await this.#ensureIdentity();
    const directory = await mkdtemp(join(tmpdir(), 'nvime-sign-'));
    const path = join(directory, 'evidence.json');
    try {
      await writeFile(path, payload, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
      return parseSignature(await this.#execute(['sign', this.#secretPath, path]));
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  async #execute(args: readonly string[]): Promise<string> {
    if (args.length < 2 || args.some((value) => !value)) throw new TypeError('trust core command is incomplete');
    try {
      const { stdout } = await run(this.executable, [...args], { timeout: 15_000, maxBuffer: 1_100_000 });
      if (!stdout.trim()) throw new Error('trust core returned no output');
      return stdout.trim();
    } catch (cause) {
      throw managedError(`trust core ${args[0]} failed`, cause);
    }
  }
}

function buildEvidence(
  session: SessionView,
  policy: OrganizationPolicy,
  device: DeviceIdentity,
  github: { repository: RepositoryIdentity; reviewerId: string },
): ReviewEvidence {
  if (!session.merge || !session.base || !session.diffId) throw managedError('merged review metadata is incomplete');
  if (session.threshold !== policy.threshold) throw managedError('review was graded under an obsolete organization threshold');
  if (session.policyId !== policy.policyId) throw managedError('review was completed under an obsolete organization policy');
  const gates = session.blocks.filter((block) => block.substantial).map((block) => gateEvidence(block, policy.threshold));
  if (gates.length === 0) throw managedError('review contains no substantial comprehension gates');
  const issued = new Date();
  const evidence = {
    schema: 'dev.nvime.attestation/v1' as const,
    repository: github.repository,
    commitSha: requireSha(session.merge.commit, 'merge commit'),
    baseSha: requireSha(session.base.commit, 'base commit'),
    diffDigest: requireDigest(session.diffId, 'diff digest'),
    policyId: policy.policyId,
    reviewerId: github.reviewerId,
    deviceKeyId: device.keyId,
    issuedAt: issued.toISOString(),
    expiresAt: new Date(issued.getTime() + 60 * 60_000).toISOString(),
    gates,
  } satisfies ReviewEvidence;
  validateEvidence(evidence);
  return evidence;
}

function gateEvidence(block: SessionView['blocks'][number], threshold: number): GateEvidence {
  const last = block.rounds.at(-1);
  const grade = last?.result?.grade;
  if (block.state !== 'resolved' || !Number.isSafeInteger(grade) || Number(grade) < threshold) {
    throw managedError(`thread is not cleared under managed policy: ${block.title}`);
  }
  if (block.signatures.length === 0 || block.rounds.length === 0) throw managedError(`thread evidence is incomplete: ${block.title}`);
  const evidenceDigest = createHash('sha256').update(block.signatures.join(':')).digest('hex');
  assert(evidenceDigest.length === 64, 'gate evidence digest must be SHA-256');
  assert(block.id.length > 0, 'gate thread ID must not be empty');
  return { threadId: block.id, grade: Number(grade), threshold, rounds: block.rounds.length, evidenceDigest };
}

function validateEvidence(evidence: ReviewEvidence): void {
  if (evidence.commitSha === evidence.baseSha) throw managedError('merge and base commit must differ');
  if (!/^github:[1-9][0-9]*$/.test(evidence.reviewerId)) throw managedError('GitHub reviewer ID is invalid');
  if (!/^device:[a-f0-9]{64}$/.test(evidence.deviceKeyId)) throw managedError('device key ID is invalid');
  if (evidence.gates.some((gate) => gate.grade < gate.threshold)) throw managedError('evidence contains an uncleared gate');
  assert(evidence.gates.length > 0, 'validated evidence must contain gates');
  assert(Date.parse(evidence.expiresAt) > Date.parse(evidence.issuedAt), 'evidence expiry must follow issuance');
}

function canonicalize(evidence: ReviewEvidence): string {
  validateEvidence(evidence);
  const value = JSON.stringify(evidence);
  if (!value.startsWith('{"schema":"dev.nvime.attestation/v1"')) throw new Error('canonical evidence field order changed');
  if (Buffer.byteLength(value) > 1_000_000) throw new RangeError('canonical evidence exceeds 1 MB');
  return value;
}

async function inspectGitHub(root: string, githubExecutable: string): Promise<{ repository: RepositoryIdentity; reviewerId: string }> {
  if (!isAbsolute(root)) throw new TypeError('GitHub repository root must be absolute');
  const remote = parseGitHubRemote(await command('git', ['-C', root, 'remote', 'get-url', 'origin']));
  const [accountId, repositoryId] = await Promise.all([
    command(githubExecutable, ['api', 'user', '--jq', '.id']),
    command(githubExecutable, ['api', `repos/${remote.owner}/${remote.name}`, '--jq', '.id']),
  ]);
  const reviewerId = `github:${positiveId(accountId, 'GitHub account')}`;
  const repository = { githubRepositoryId: positiveId(repositoryId, 'GitHub repository'), ...remote };
  assert(repository.githubRepositoryId > 0, 'GitHub repository ID must be positive');
  assert(reviewerId.startsWith('github:'), 'reviewer ID must use the GitHub namespace');
  return { repository, reviewerId };
}

async function verifyLandedHead(session: SessionView): Promise<void> {
  if (!session.merge) throw managedError('change has not merged');
  const head = await command('git', ['-C', session.repoRoot, 'rev-parse', 'HEAD']);
  if (head !== session.merge.commit) throw managedError('repository HEAD no longer matches the reviewed merge commit');
  assert(SHA.test(head), 'verified repository HEAD must be a Git SHA');
  assert(session.merge.commit.length >= 40, 'recorded merge commit must be a Git SHA');
}

export function parseGitHubRemote(value: string): { owner: string; name: string } {
  if (!value || value.length > 2_000) throw managedError('GitHub origin URL is invalid');
  const match = /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([^/]+)\/([^/]+?)(?:\.git)?$/.exec(value.trim());
  const owner = match?.[1];
  const name = match?.[2];
  if (!owner || !name || !SLUG.test(owner) || !SLUG.test(name)) throw managedError('origin must be a github.com repository');
  assert(!name.endsWith('.git'), 'parsed GitHub repository must omit .git');
  assert(`${owner}/${name}`.split('/').length === 2, 'GitHub repository must have one owner and name');
  return { owner, name };
}

async function command(executable: string, args: readonly string[]): Promise<string> {
  if (!executable || args.length === 0 || args.some((value) => !value)) throw new TypeError('external command is incomplete');
  try {
    const { stdout } = await run(executable, [...args], { timeout: 15_000, maxBuffer: 1_000_000 });
    if (!stdout.trim()) throw new Error('command returned no output');
    return stdout.trim();
  } catch (cause) {
    throw managedError(`${executable} ${args[0]} failed`, cause);
  }
}

function parseSignature(value: string): { signature: string; publicKey: string } {
  let root: unknown;
  try { root = JSON.parse(value); }
  catch (cause) { throw managedError('trust core returned invalid JSON', cause); }
  if (typeof root !== 'object' || root === null || Array.isArray(root)) throw managedError('trust core signature must be an object');
  const signature = (root as Record<string, unknown>).signature;
  const publicKey = (root as Record<string, unknown>).publicKey;
  if (typeof signature !== 'string' || Buffer.from(signature, 'base64').length !== 64) throw managedError('trust core signature is invalid');
  if (typeof publicKey !== 'string' || Buffer.from(publicKey, 'base64').length !== 44) throw managedError('trust core public key is invalid');
  return { signature, publicKey };
}

function positiveId(value: string, label: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) throw managedError(`${label} ID is invalid`);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number <= 0) throw managedError(`${label} ID is invalid`);
  return number;
}

function requireSha(value: string, label: string): string {
  if (!SHA.test(value)) throw managedError(`${label} is invalid`);
  return value;
}

function requireDigest(value: string, label: string): string {
  if (!/^[a-f0-9]{64}$/.test(value)) throw managedError(`${label} is invalid`);
  return value;
}

function managedError(message: string, cause?: unknown): ProtocolError {
  return new ProtocolError('agent_error', message, cause === undefined ? undefined : String(cause));
}
