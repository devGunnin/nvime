import assert from 'node:assert/strict';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { afterEach, describe, it } from 'node:test';
import { ManagedPolicyClient, parseOrganizationPolicy } from '../src/managed-policy.js';
import { ProtocolError } from '../src/protocol.js';

const POLICY = {
  schema: 'dev.nvime.organization-policy/v1',
  policyId: 'org:42:policy:7',
  organizationId: 42,
  revision: 7,
  gateMode: 'medium',
  threshold: 70,
  allowedProviders: ['claude', 'codex'],
  interactionMode: 'user-choice',
  updatedAt: '2026-09-02T10:00:00.000Z',
};

let server: Server | null = null;

afterEach(async () => {
  if (server) await new Promise<void>((resolve, reject) => server?.close((error) => error ? reject(error) : resolve()));
  server = null;
});

async function serve(handler: (request: IncomingMessage, response: ServerResponse) => void): Promise<string> {
  server = createServer(handler);
  await new Promise<void>((resolve, reject) => {
    assert(server !== null, 'server must exist before listen');
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address !== null && typeof address === 'object', 'test server must use a TCP address');
  assert(address.port > 0, 'test server must receive an ephemeral port');
  return `http://127.0.0.1:${address.port}`;
}

describe('organization policy boundary', () => {
  it('accepts an exact, internally consistent policy', () => {
    const policy = parseOrganizationPolicy(POLICY);
    assert.equal(policy.policyId, 'org:42:policy:7');
    assert.deepEqual(policy.allowedProviders, ['claude', 'codex']);
  });

  it('rejects inconsistent gates and duplicate providers', () => {
    assert.throws(() => parseOrganizationPolicy({ ...POLICY, threshold: 69 }), ProtocolError);
    assert.throws(() => parseOrganizationPolicy({ ...POLICY, allowedProviders: ['claude', 'claude'] }), ProtocolError);
  });

  it('requires HTTPS except on an explicit loopback address', () => {
    assert.throws(() => new ManagedPolicyClient('http://control.example.com'), /HTTPS/);
    assert.throws(() => new ManagedPolicyClient('https://user:secret@control.example.com'), /credentials/);
    assert.doesNotThrow(() => new ManagedPolicyClient('http://127.0.0.1:4817'));
  });

  it('fetches policy and refuses a provider the sidecar cannot honor', async () => {
    const base = await serve((_request, response) => {
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify({ ...POLICY, allowedProviders: ['codex'] }));
    });
    await assert.rejects(() => new ManagedPolicyClient(base).policy(), /does not allow Claude/);
    assert(server !== null, 'request must leave the server lifecycle intact');
  });

  it('keeps HTTP failures and oversized responses visible', async () => {
    const base = await serve((_request, response) => {
      response.statusCode = 402;
      response.end('subscription required');
    });
    await assert.rejects(() => new ManagedPolicyClient(base).policy(), /HTTP 402/);
    assert(server !== null, 'failed requests must not hide server state');
  });
});
