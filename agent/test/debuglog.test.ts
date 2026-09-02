import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { DebugLog, MAX_BYTES, MAX_PAYLOAD_CHARS, REDACTED, isSecretKey, renderParams } from '../src/debuglog.js';
import { ProtocolError } from '../src/protocol.js';

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
    // The first line is `setLevel`'s trial append, which is how a mirror that
    // cannot write is refused rather than latched silently.
    const written = readFileSync(path, 'utf8').trim().split('\n');
    assert.equal(written.length, 3, written.join('\n'));
    assert.ok(written[0]?.includes('mirror on at info'), written.join('\n'));
    assert.ok(written[1]?.includes('big.merge'), written.join('\n'));
    assert.ok(written[2]?.includes('1234ms'), written.join('\n'));
    assert.ok(written[2]?.includes('ok'), written.join('\n'));
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

  it('summarises a content key whatever it holds, and never walks into it', () => {
    // Round 3: the type-sniffing escape hatch this used to assert is gone. A
    // content key that recursed put `spec.goal` one field beyond the rule.
    assert.ok(renderParams({ answers: [{ text: 'a' }, { text: 'b' }] }).includes('<2 items>'));
    assert.ok(renderParams({ prompt: 'a prompt' }).includes('<8 chars>'));
    assert.match(renderParams({ spec: { goal: 'ship it', scope: [] } }), /keys/);
  });

  it('judges a settings object by its own field names, not by the name above it', () => {
    // Why `context` is no longer a content key at all: it is a block list in an
    // RPC payload and a settings object in the config the bundle renders.
    assert.ok(renderParams({ context: { maxFileBytes: 204800 } }).includes('204800'));
    assert.ok(renderParams({ context: [{ path: 'a', text: 'x' }] }).includes('<1 chars>'));
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

describe('DebugLog round-2 regressions', () => {
  // G1: a big change's branch is `nvime/big/<slug of the title>`, and the
  // title is the first 80 characters of what the user typed. Recorded by size
  // on both halves, so the wire may carry it as its own named field.
  it('treats title-derived names as content on this half too', () => {
    for (const key of ['branch', 'title', 'slug']) {
      const rendered = renderParams({ [key]: 'nvime/big/fix-the-hunter2-staging-password' });
      assert.ok(!rendered.includes('hunter2'), `${key} reached the log: ${rendered}`);
      assert.ok(rendered.includes('chars>'), `${key} should be recorded as a size: ${rendered}`);
    }
  });

  // G7: the runner's socket and its token together are a live control channel.
  it('redacts the runner control socket', () => {
    const rendered = renderParams({ runner: { pid: 4242, socket: '/run/user/1000/nvime/SECRET.sock' } });
    assert.ok(!rendered.includes('SECRET.sock'), rendered);
    assert.ok(rendered.includes(REDACTED), rendered);
    assert.ok(rendered.includes('4242'), 'the pid is the diagnostic signal and is kept');
  });

  // G6: a failed mirror latched and wrote one line to stderr, which the plugin
  // only ever sees after the sidecar dies. `debug.set` had already said ok.
  it('refuses a level it cannot actually write, instead of answering ok', () => {
    const log = new DebugLog();
    assert.throws(
      () => log.setLevel('info', join(mkdtempSync(join(tmpdir(), 'nvime-dl-')), 'gone', 'nvime-1.log')),
      (error: unknown) => error instanceof ProtocolError,
    );
    assert.equal(log.level, 'off', 'a mirror that cannot write is off, not silently broken');
  });

  // G5: `#append` chmodded only when it had created the file, so pointing the
  // mirror at a pre-existing 0644 file left it world-readable.
  it('tightens a pre-existing file to 0600 on its first append', () => {
    const path = scratch();
    writeFileSync(path, 'already here\n');
    chmodSync(path, 0o644);
    const log = new DebugLog();
    log.setLevel('info', path);
    log.note('one');
    assert.equal(statSync(path).mode & 0o777, 0o600);
  });

  // G8: `detail()` had no caller, so `:Nvime debug debug` cost a round trip
  // and changed nothing on this half.
  it('mirrors a streamed delta by size at debug level, and not at info', () => {
    const quiet = scratch();
    const atInfo = new DebugLog();
    atInfo.setLevel('info', quiet);
    atInfo.detail('big.delta 41 bytes');
    assert.ok(!readFileSync(quiet, 'utf8').includes('big.delta'), 'info keeps the per-token detail out');

    const loud = scratch();
    const atDebug = new DebugLog();
    atDebug.setLevel('debug', loud);
    atDebug.detail('big.delta 41 bytes');
    assert.ok(readFileSync(loud, 'utf8').includes('big.delta 41 bytes'), 'debug takes it');
  });
});

describe('DebugLog round-3 regressions', () => {
  // D1: `spec` was a content key, but the summariser only fired for a string
  // or an array — so an object walked straight through it and the approved
  // plan's `goal`/`approach` were written out verbatim.
  const SPEC = {
    goal: 'stop the hunter2 staging password leaking into auth logs',
    scope: ['src/hunter2_auth.rs'],
    approach: 'rotate the hunter2 credential and scrub the log sink',
    acceptance: ['no hunter2 in any sink'],
    outOfScope: ['the hunter2 rotation runbook'],
  };

  it('summarises a content-named object rather than walking into it', () => {
    const rendered = renderParams({ session: { id: 'sess', spec: SPEC } });
    assert.ok(!rendered.includes('hunter2'), rendered);
    assert.ok(/keys/.test(rendered), `the shape is still described: ${rendered}`);
  });

  it('holds for each spec field arriving on its own', () => {
    for (const [key, value] of Object.entries(SPEC)) {
      const rendered = renderParams({ [key]: value });
      assert.ok(!rendered.includes('hunter2'), `${key} reached the log: ${rendered}`);
    }
  });

  it('still judges an ordinary settings object by its own field names', () => {
    const rendered = renderParams({ context: { maxFileBytes: 204800, blocks: [{ text: 'secret' }] } });
    assert.ok(rendered.includes('204800'), `a number is not content: ${rendered}`);
    assert.ok(!rendered.includes('secret'), `and the text inside it still is: ${rendered}`);
  });
});

describe('DebugLog round-4 regressions', () => {
  // R1: round 3 dropped `context` from the content keys — correctly, it means
  // two different things — but nothing else named the `dir` block's `entries`,
  // which is a listing of the reader's own disk.
  it('records an attached directory listing by size, not by name', () => {
    const rendered = renderParams({
      context: [
        { type: 'file', path: '/home/me/a.md', text: 'the hunter2 note' },
        { type: 'dir', path: '/home/me/notes', entries: ['acme-hunter2.md', 'b.md'] },
      ],
    });
    assert.ok(!rendered.includes('hunter2'), rendered);
    assert.ok(rendered.includes('items>'), `still recorded as a size: ${rendered}`);
  });

  // A short field nobody named fits inside the clip and is written out whole.
  it('records each user-authored field by size, one probe per name', () => {
    const named: Record<string, unknown> = {
      answer: 'my hunter2 defence of this thread',
      followup: 'what about hunter2 in the retry path?',
      ungraded: 'could not grade the hunter2 thread',
      label: 'use the hunter2 staging credential',
      detail: 'reads /etc/hunter2.conf',
      entries: ['hunter2.md'],
      lines: ['-old hunter2', '+new'],
    };
    for (const [key, value] of Object.entries(named)) {
      const rendered = renderParams({ [key]: value });
      assert.ok(!rendered.includes('hunter2'), `${key} was written out whole: ${rendered}`);
    }
  });
});
