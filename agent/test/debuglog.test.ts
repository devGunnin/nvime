import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { DebugLog, MAX_BYTES, MAX_PAYLOAD_CHARS, REDACTED, isSecretKey, renderParams } from '../src/debuglog.js';

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

describe('DebugLog round-1 regressions', () => {
  // F4: the template literal was built before `#write` looked at the level, so
  // a 1000-token stream paid a full redact + JSON.stringify per delta at `off`.
  it('formats nothing at all while off', () => {
    const log = new DebugLog();
    const real = JSON.stringify;
    let calls = 0;
    (JSON as { stringify: typeof JSON.stringify }).stringify = ((...args: Parameters<typeof real>) => {
      calls += 1;
      return real(...args);
    }) as typeof JSON.stringify;
    try {
      for (let index = 0; index < 1000; index += 1) log.request('big.delta', index, { text: `t${index}` });
      log.reply('big.delta', 1, 5);
      log.note('anything');
    } finally {
      (JSON as { stringify: typeof JSON.stringify }).stringify = real;
    }
    assert.equal(calls, 0, 'an off log must not encode anything');
  });

  // F8: `#bytes` only ever moved in setLevel, so one rotation by the plugin
  // stopped the sidecar half of the timeline for the rest of the session,
  // silently.
  it('says once that it stopped at the cap, then resumes after the plugin rotates', () => {
    const path = scratch();
    writeFileSync(path, 'x'.repeat(MAX_BYTES + 1024));
    const log = new DebugLog();
    log.setLevel('info', path);
    log.note('dropped one');
    log.note('dropped two');
    const atCap = readFileSync(path, 'utf8');
    assert.ok(atCap.includes('mirror stopped'), 'the mirror must say it stopped, not vanish');
    assert.ok(!atCap.includes('dropped one'), 'and it really does stop');
    assert.equal(atCap.split('mirror stopped').length - 1, 1, 'said once, not per line');

    // The plugin rotates: the file it points at is now small again.
    writeFileSync(path, '');
    log.note('after the rotation');
    assert.ok(readFileSync(path, 'utf8').includes('after the rotation'), 'the mirror must come back');
  });

  // F9: `appendFileSync` takes the umask, so the shared log landed 0644.
  it('creates the file 0600', () => {
    const path = scratch();
    const log = new DebugLog();
    log.setLevel('info', path);
    log.note('one');
    assert.equal(statSync(path).mode & 0o777, 0o600, 'the shared log must be owner-only');
  });
});
