import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { DebugLog, MAX_PAYLOAD_CHARS, REDACTED, isSecretKey, renderParams } from '../src/debuglog.js';

function scratch(): string {
  return join(mkdtempSync(join(tmpdir(), 'nvime-debuglog-')), 'nvime.log');
}

describe('DebugLog level', () => {
  it('writes nothing and creates no file while off', () => {
    const path = scratch();
    const log = new DebugLog();
    log.request('big.merge', 7, { root: '/repo' });
    log.reply('big.merge', 7, 12);
    log.note('anything at all');
    assert.equal(existsSync(path), false);
  });

  it('records a request and its reply once switched on', () => {
    const path = scratch();
    const log = new DebugLog();
    log.setLevel('info', path);
    log.request('big.merge', 7, { root: '/repo' });
    log.reply('big.merge', 7, 1234);
    const written = readFileSync(path, 'utf8').trim().split('\n');
    assert.equal(written.length, 2);
    assert.ok(written[0]?.includes('big.merge'), written.join('\n'));
    assert.ok(written[1]?.includes('1234ms'), written.join('\n'));
    assert.ok(written[1]?.includes('ok'), written.join('\n'));
  });

  it('names the failure on a reply that carried one', () => {
    const path = scratch();
    const log = new DebugLog();
    log.setLevel('info', path);
    log.reply('big.merge', 9, 5, 'base-moved');
    assert.ok(readFileSync(path, 'utf8').includes('base-moved'));
  });

  it('stops writing again when switched back off', () => {
    const path = scratch();
    const log = new DebugLog();
    log.setLevel('info', path);
    log.note('one');
    log.setLevel('off', null);
    log.note('two');
    const body = readFileSync(path, 'utf8');
    assert.ok(body.includes('one'));
    assert.ok(!body.includes('two'), 'an off log must stop writing');
  });

  it('rejects a level it does not know', () => {
    const log = new DebugLog();
    assert.throws(() => log.setLevel('verbose' as never, scratch()), /level/);
  });

  it('refuses to grow a file already past the cap rather than rotating under the plugin', () => {
    const path = scratch();
    writeFileSync(path, 'x'.repeat(6 * 1024 * 1024));
    const log = new DebugLog();
    log.setLevel('info', path);
    log.note('this must not be appended');
    assert.ok(!readFileSync(path, 'utf8').includes('must not be appended'));
  });
});

describe('DebugLog redaction', () => {
  it('treats secret-shaped names as secret and ordinary ones as not', () => {
    for (const name of ['token', 'accessToken', 'api_key', 'apiKey', 'key', 'secret', 'Authorization']) {
      assert.ok(isSecretKey(name), `${name} must be treated as a secret`);
    }
    for (const name of ['keymaps', 'monkey', 'sessionId', 'root', 'difficulty']) {
      assert.ok(!isSecretKey(name), `${name} must not be mistaken for a secret`);
    }
  });

  it('never writes a secret value out', () => {
    const rendered = renderParams({ root: '/repo', organization: { api_key: 'sk-ant-notreal-1' } });
    assert.ok(!rendered.includes('sk-ant-notreal-1'), rendered);
    assert.ok(rendered.includes(REDACTED), rendered);
  });

  it('summarises user content instead of quoting it', () => {
    const rendered = renderParams({ prompt: 'a'.repeat(400) });
    assert.ok(!rendered.includes('aaaa'), rendered);
    assert.ok(rendered.includes('400 chars'), rendered);
  });

  it('summarises a content-named list but keeps a settings object of the same name', () => {
    assert.ok(renderParams({ context: [{ path: 'a' }, { path: 'b' }] }).includes('<2 items>'));
    assert.ok(renderParams({ context: { maxFileBytes: 204800 } }).includes('204800'));
  });

  it('clips a long payload to the line budget', () => {
    const rendered = renderParams({ root: '/deep'.repeat(200) });
    assert.ok(rendered.length <= MAX_PAYLOAD_CHARS + 16, `payload was ${rendered.length}`);
  });

  it('keeps a secret out of the file the plugin will attach to a bug report', () => {
    const path = scratch();
    const log = new DebugLog();
    log.setLevel('info', path);
    log.request('organization.attest', 3, { token: 'sk-ant-notreal-2' });
    assert.ok(!readFileSync(path, 'utf8').includes('sk-ant-notreal-2'), 'REDACTION BOUNDARY');
  });
});
