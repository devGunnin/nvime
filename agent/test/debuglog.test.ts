import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import {
  DebugLog,
  MAX_BYTES,
  MAX_PAYLOAD_CHARS,
  REDACTED,
  SAFE_KEYS,
  isSecretKey,
  renderParams,
} from '../src/debuglog.js';
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

  it('reduces anything not vouched for, whatever shape it arrives in', () => {
    // Round 5: there is no list of dangerous names any more. A string needs a
    // safe name; a list needs a safe name AND numeric elements; an object
    // recurses so each leaf answers for itself.
    assert.ok(renderParams({ answers: [{ text: 'a' }, { text: 'b' }] }).includes('<2 items>'));
    assert.ok(renderParams({ prompt: 'a prompt' }).includes('<8 chars>'));
    assert.ok(renderParams({ spec: { goal: 'ship it' } }).includes('<7 chars>'), 'the leaf answers for itself');
  });

  it('lets a number through under any name, and a string under none', () => {
    assert.ok(renderParams({ context: { maxFileBytes: 204800 } }).includes('204800'));
    assert.ok(renderParams({ context: [{ path: 'a', text: 'x' }] }).includes('<1 items>'));
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

  it('never writes the approved plan, however it is nested', () => {
    const rendered = renderParams({ session: { id: 'sess', spec: SPEC } });
    assert.ok(!rendered.includes('hunter2'), rendered);
    assert.ok(rendered.includes('sess'), `the identifier still reads: ${rendered}`);
    assert.ok(rendered.includes('chars>'), `and the plan's leaves are sized: ${rendered}`);
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

describe('DebugLog round-5: deny by default', () => {
  const MARKER = 'hunter2';

  it('writes a string under a name nobody vouched for as a size', () => {
    const rendered = renderParams({ zzzUnthoughtOf: `the ${MARKER} staging password` });
    assert.ok(!rendered.includes(MARKER), rendered);
    assert.ok(rendered.includes('chars>'), rendered);
  });

  // `reason` was a candidate. It is not an enum: policy.ts builds prose that
  // embeds an error message and a path, steer returns an arbitrary close
  // reason, and triage sets it from `cause.message`.
  it('denies reason, which carries free text however enum-shaped it looks', () => {
    const rendered = renderParams({ tool: 'Write', reason: `could not resolve /etc/${MARKER}.conf` });
    assert.ok(!rendered.includes(MARKER), rendered);
    assert.ok(rendered.includes('Write'), 'the tool name is the diagnostic signal and stays');
  });

  it('recurses into an object so its leaves are judged by their own names', () => {
    const rendered = renderParams({ session: { id: 'sess', display: 'building', spec: { goal: MARKER } } });
    assert.ok(!rendered.includes(MARKER), rendered);
    assert.ok(rendered.includes('building'), 'a safe leaf under an unsafe parent still reads');
  });

  it('passes numbers and booleans through whatever they are called', () => {
    const rendered = renderParams({ anythingAtAll: 42, whatever: true });
    assert.ok(rendered.includes('42') && rendered.includes('true'), rendered);
  });

  it('keeps a list of strings as a count, even under a safe name', () => {
    assert.ok(renderParams({ files: ['a.rs', 'b.rs'] }).includes('<2 items>'));
    assert.ok(renderParams({ seq: [1, 2, 3] }).includes('[1,2,3]'));
  });

  it('gives a secret name precedence over a safe one', () => {
    const rendered = renderParams({ path: '/home/me/proj', socket: '/run/user/1/x.sock' });
    assert.ok(rendered.includes('/home/me/proj'), rendered);
    assert.ok(!rendered.includes('x.sock'), rendered);
    assert.ok(rendered.includes(REDACTED), rendered);
  });

  it('never lets the clip be the reason something is safe', () => {
    assert.ok(!renderParams({ unnamed: MARKER }).includes(MARKER));
  });

  it('renders every safe key that carries a string', () => {
    for (const key of SAFE_KEYS) {
      const value = `v-${key}`;
      assert.ok(renderParams({ [key]: value }).includes(value), `${key} is safe but did not render`);
    }
  });

  it('never writes a sentinel under 200 random shapes', () => {
    // A tiny seeded LCG, so a failure is reproducible.
    let seed = 20260902;
    const rand = (n: number): number => {
      seed = (seed * 1103515245 + 12345) % 2147483648;
      return (seed % n) + 1;
    };
    const noise = (depth: number): unknown => {
      if (depth <= 0 || rand(3) === 1) return `leading ${MARKER} trailing`;
      const out: Record<string, unknown> = {};
      for (let index = 1; index <= rand(4); index += 1) out[`k${rand(100000)}_${index}`] = noise(depth - 1);
      return out;
    };
    for (let index = 0; index < 200; index += 1) {
      assert.ok(!renderParams(noise(4)).includes(MARKER), `a random shape leaked on run ${index}`);
    }
  });
});

describe('DebugLog round-6: a safe key needs a producer', () => {
  const MARKER = 'hunter2';

  // F1: `runsock.ts` accepts any string as a steer's `from` and only ever
  // renders it, so the label is the peer's, not machine identity.
  it('denies a steer origin, which a peer chooses the text of', () => {
    const rendered = renderParams({ state: 'queued', origin: `from-${MARKER}`, mine: false });
    assert.ok(!rendered.includes(MARKER), rendered);
    assert.ok(rendered.includes('queued'), 'the steer state is nvime’s own and stays');
  });

  // F7: a safe name with no producer is a free pass for whatever gets that
  // name next; `model` is typed by hand at `:Nvime model`.
  it('denies a name nothing produces, and one the reader types', () => {
    assert.ok(!renderParams({ outcome: MARKER }).includes(MARKER));
    assert.ok(!renderParams({ model: `my-${MARKER}-model` }).includes(MARKER));
  });
});
