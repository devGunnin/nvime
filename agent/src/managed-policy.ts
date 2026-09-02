import assert from 'node:assert/strict';
import { ProtocolError } from './protocol.js';

export type GateMode = 'easy' | 'medium' | 'extreme' | 'manual';

export interface OrganizationPolicy {
  readonly schema: 'dev.nvime.organization-policy/v1';
  readonly policyId: string;
  readonly organizationId: number;
  readonly revision: number;
  readonly gateMode: GateMode;
  readonly threshold: number;
  readonly allowedProviders: readonly ('claude' | 'codex' | 'copilot')[];
  readonly interactionMode: 'user-choice' | 'modal' | 'standard';
  readonly updatedAt: string;
}

const MAX_RESPONSE_BYTES = 1_000_000;

export class ManagedPolicyClient {
  readonly #policyEndpoint: URL;
  readonly #attestationEndpoint: URL;

  constructor(baseUrl: string) {
    const base = secureBaseUrl(baseUrl);
    this.#policyEndpoint = new URL('/v1/policy', base);
    this.#attestationEndpoint = new URL('/v1/attestations', base);
    assert(this.#policyEndpoint.origin === this.#attestationEndpoint.origin, 'managed endpoints must share an origin');
    assert(this.#policyEndpoint.pathname !== this.#attestationEndpoint.pathname, 'managed endpoint paths must differ');
  }

  async policy(): Promise<OrganizationPolicy> {
    const response = await request(this.#policyEndpoint, { headers: { accept: 'application/json' } }, 10_000);
    const value = JSON.parse(await boundedText(response));
    const policy = parseOrganizationPolicy(value);
    if (!policy.allowedProviders.includes('claude')) {
      throw new ProtocolError('agent_error', 'organization policy does not allow Claude Code');
    }
    return policy;
  }

  async submit(value: unknown, commitSha: string): Promise<{ commitSha: string; verifiedAt: string }> {
    if (!/^[a-f0-9]{40,64}$/.test(commitSha)) throw new TypeError('attestation commit SHA is invalid');
    const response = await request(this.#attestationEndpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(value),
    }, 15_000);
    const result = record(JSON.parse(await boundedText(response)), 'attestation response');
    if (result.commitSha !== commitSha || typeof result.verifiedAt !== 'string') {
      throw new ProtocolError('agent_error', 'control plane acknowledged a different attestation');
    }
    if (!Number.isFinite(Date.parse(result.verifiedAt))) {
      throw new ProtocolError('agent_error', 'control plane returned an invalid verification time');
    }
    return { commitSha, verifiedAt: result.verifiedAt };
  }
}

export function parseOrganizationPolicy(value: unknown): OrganizationPolicy {
  const root = record(value, 'organization policy');
  if (root.schema !== 'dev.nvime.organization-policy/v1') throw invalid('unsupported organization policy schema');
  const gateMode = enumeration(root.gateMode, ['easy', 'medium', 'extreme', 'manual'], 'gate mode');
  const threshold = integer(root.threshold, 'policy threshold', 1, 100);
  const expected = { easy: 40, medium: 70, extreme: 90 }[gateMode as 'easy' | 'medium' | 'extreme'];
  if (expected !== undefined && threshold !== expected) throw invalid(`${gateMode} policy threshold must be ${expected}`);
  if (!Array.isArray(root.allowedProviders) || root.allowedProviders.length === 0) throw invalid('policy must allow a provider');
  const allowedProviders = root.allowedProviders.map((provider) =>
    enumeration(provider, ['claude', 'codex', 'copilot'], 'allowed provider'));
  if (new Set(allowedProviders).size !== allowedProviders.length) throw invalid('allowed providers must be unique');
  const policy = {
    schema: 'dev.nvime.organization-policy/v1' as const,
    policyId: string(root.policyId, 'policy ID', 1_000),
    organizationId: integer(root.organizationId, 'organization ID', 1, Number.MAX_SAFE_INTEGER),
    revision: integer(root.revision, 'policy revision', 1, Number.MAX_SAFE_INTEGER),
    gateMode,
    threshold,
    allowedProviders,
    interactionMode: enumeration(root.interactionMode, ['user-choice', 'modal', 'standard'], 'interaction mode'),
    updatedAt: isoDate(root.updatedAt, 'policy update time'),
  } satisfies OrganizationPolicy;
  assert(policy.threshold >= 1 && policy.threshold <= 100, 'parsed policy threshold must be bounded');
  assert(policy.allowedProviders.length > 0, 'parsed policy must allow at least one provider');
  return policy;
}

function secureBaseUrl(value: string): URL {
  let url: URL;
  try { url = new URL(value); }
  catch (cause) { throw new ProtocolError('bad_request', 'organization control-plane URL is invalid', String(cause)); }
  const loopback = ['127.0.0.1', 'localhost', '::1'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new ProtocolError('bad_request', 'organization control plane must use HTTPS or loopback HTTP');
  }
  if (url.username || url.password || url.search || url.hash) throw new ProtocolError('bad_request', 'organization control-plane URL must not contain credentials, query, or fragment');
  return url;
}

async function request(url: URL, init: RequestInit, timeout: number): Promise<Response> {
  let response: Response;
  try { response = await fetch(url, { ...init, signal: AbortSignal.timeout(timeout) }); }
  catch (cause) { throw new ProtocolError('agent_error', 'organization control plane is unavailable', String(cause)); }
  if (!response.ok) {
    const detail = (await boundedText(response)).slice(0, 2_000);
    throw new ProtocolError('agent_error', `organization control plane returned HTTP ${response.status}`, detail);
  }
  return response;
}

async function boundedText(response: Response): Promise<string> {
  const declared = Number(response.headers.get('content-length'));
  if (Number.isFinite(declared) && declared > MAX_RESPONSE_BYTES) throw invalid('control-plane response exceeds 1 MB');
  const text = await response.text();
  if (Buffer.byteLength(text, 'utf8') > MAX_RESPONSE_BYTES) throw invalid('control-plane response exceeds 1 MB');
  return text;
}

function invalid(message: string): ProtocolError {
  return new ProtocolError('agent_error', message);
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw invalid(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function string(value: unknown, label: string, maximum: number): string {
  if (typeof value !== 'string' || !value.trim()) throw invalid(`${label} must be a non-empty string`);
  if (value.length > maximum) throw invalid(`${label} is too long`);
  return value;
}

function integer(value: unknown, label: string, minimum: number, maximum: number): number {
  if (!Number.isSafeInteger(value) || Number(value) < minimum || Number(value) > maximum) throw invalid(`${label} is invalid`);
  return Number(value);
}

function enumeration<const T extends string>(value: unknown, values: readonly T[], label: string): T {
  if (typeof value !== 'string' || !values.includes(value as T)) throw invalid(`${label} is invalid`);
  return value as T;
}

function isoDate(value: unknown, label: string): string {
  const text = string(value, label, 64);
  if (!Number.isFinite(Date.parse(text)) || new Date(text).toISOString() !== text) throw invalid(`${label} must be canonical ISO-8601`);
  return text;
}
