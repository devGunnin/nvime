import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import type { RunEvent } from '../src/runlog.js';
import {
  connectControl,
  ensureSocketDir,
  isServed,
  MAX_SOCKET_PATH_BYTES,
  parseControlRequest,
  serveControl,
  socketPathFor,
  type ControlHandlers,
  type ControlServer,
} from '../src/runsock.js';

let root = '';
let runtime = '';
let server: ControlServer | null = null;

const event = (seq: number, name = 'big.delta'): RunEvent => ({ seq, at: 1, event: name, params: { text: `#${seq}` } });

function handlers(overrides: Partial<ControlHandlers> = {}): ControlHandlers {
  return {
    replay: (after) => [event(1), event(2), event(3)].filter((entry) => entry.seq > after),
    steer: () => ({ queued: true }),
    cancel: () => undefined,
    info: () => ({ pid: process.pid, what: 'build', seq: 3 }),
    ...overrides,
  };
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-sock-'));
  runtime = join(root, 'run');
  mkdirSync(runtime, { recursive: true });
});

afterEach(async () => {
  await server?.close();
  server = null;
  rmSync(root, { recursive: true, force: true });
});

describe('socketPathFor', () => {
  it('puts the socket under XDG_RUNTIME_DIR, keyed by the session', () => {
    const path = socketPathFor({ XDG_RUNTIME_DIR: runtime }, '/repo', 'abc');
    assert.ok(path.startsWith(join(runtime, 'nvime')), path);
    assert.equal(path, socketPathFor({ XDG_RUNTIME_DIR: runtime }, '/repo', 'abc'), 'stable for one session');
    assert.notEqual(path, socketPathFor({ XDG_RUNTIME_DIR: runtime }, '/repo', 'abd'), 'and per session');
    assert.notEqual(path, socketPathFor({ XDG_RUNTIME_DIR: runtime }, '/other', 'abc'), 'and per repo');
  });

  it('falls back to a per-user temp directory when the runtime dir would be too long', () => {
    const long = `/${'d'.repeat(MAX_SOCKET_PATH_BYTES)}`;
    const path = socketPathFor({ XDG_RUNTIME_DIR: long }, '/repo', 'abc');
    assert.ok(!path.startsWith(long), 'the long runtime dir is skipped');
    assert.ok(Buffer.byteLength(path, 'utf8') <= MAX_SOCKET_PATH_BYTES, path);
  });

  it('never returns a path a unix socket cannot hold', () => {
    for (const dir of [undefined, runtime, `/${'d'.repeat(200)}`]) {
      const path = socketPathFor(dir === undefined ? {} : { XDG_RUNTIME_DIR: dir }, '/repo', 'abc');
      assert.ok(Buffer.byteLength(path, 'utf8') <= MAX_SOCKET_PATH_BYTES, `${path} is too long`);
    }
  });
});

describe('ensureSocketDir', () => {
  it('creates the directory private to this user', () => {
    const dir = ensureSocketDir(join(runtime, 'nvime', 'x.sock'));
    assert.equal(dir, join(runtime, 'nvime'));
  });

  it('tightens a directory a loose umask left readable', () => {
    const dir = join(root, 'loose');
    mkdirSync(dir, { recursive: true });
    chmodSync(dir, 0o777);
    ensureSocketDir(join(dir, 'x.sock'));
    assert.equal(statSync(dir).mode & 0o777, 0o700);
  });

  it('refuses a symlink standing where the directory should be', () => {
    const real = join(root, 'elsewhere');
    mkdirSync(real, { recursive: true });
    const link = join(root, 'planted');
    symlinkSync(real, link);
    assert.throws(() => ensureSocketDir(join(link, 'x.sock')), /not a directory/);
  });

  it('refuses a plain file standing where the directory should be', () => {
    const file = join(root, 'not-a-dir');
    writeFileSync(file, 'x');
    assert.throws(() => ensureSocketDir(join(file, 'x.sock')));
  });
});

describe('serveControl', () => {
  it('replays from an offset and then follows live, in order', async () => {
    const path = join(runtime, 'a.sock');
    server = await serveControl(path, handlers());
    const client = await connectControl(path);
    const seen: number[] = [];
    const ack = await client.attach(1, (entry) => seen.push(entry.seq));
    assert.equal(ack.replayed, 2);
    server.broadcast(event(4));
    await settle();
    assert.deepEqual(seen, [2, 3, 4]);
    client.close();
  });

  it('broadcasts to every attached viewer', async () => {
    const path = join(runtime, 'b.sock');
    server = await serveControl(path, handlers());
    const first = await connectControl(path);
    const second = await connectControl(path);
    const a: number[] = [];
    const b: number[] = [];
    await first.attach(3, (entry) => a.push(entry.seq));
    await second.attach(3, (entry) => b.push(entry.seq));
    assert.equal(server.attached, 2);
    server.broadcast(event(4));
    await settle();
    assert.deepEqual(a, [4]);
    assert.deepEqual(b, [4]);
    first.close();
    second.close();
  });

  it('answers a ping with the runner behind it', async () => {
    const path = join(runtime, 'c.sock');
    server = await serveControl(path, handlers());
    const client = await connectControl(path);
    assert.deepEqual(await client.ping(), { pid: process.pid, what: 'build', seq: 3 });
    client.close();
  });

  it('turns a refused steer into an error the caller sees, not a silent drop', async () => {
    const path = join(runtime, 'd.sock');
    server = await serveControl(path, handlers({ steer: () => ({ queued: false, reason: 'the build has finished' }) }));
    const client = await connectControl(path);
    await assert.rejects(client.steer('too late'), /the build has finished/);
    client.close();
  });

  it('runs cancel on the runner', async () => {
    const path = join(runtime, 'e.sock');
    let cancelled = 0;
    server = await serveControl(path, handlers({ cancel: () => (cancelled += 1) }));
    const client = await connectControl(path);
    await client.cancel();
    assert.equal(cancelled, 1);
    client.close();
  });

  it('takes over a socket file no runner is behind, and refuses one that is', async () => {
    const path = join(runtime, 'f.sock');
    server = await serveControl(path, handlers());
    await assert.rejects(serveControl(path, handlers()), /already serving/);
    await server.close();
    server = null;

    // A leftover file with nothing listening: the next runner reclaims it.
    mkdirSync(join(runtime), { recursive: true });
    writeFileSync(path, '');
    assert.equal(await isServed(path), false);
    server = await serveControl(path, handlers());
    assert.equal(await isServed(path), true);
  });

  it('rejects a malformed frame without dropping the connection', async () => {
    const path = join(runtime, 'g.sock');
    server = await serveControl(path, handlers());
    const client = await connectControl(path);
    // A well-formed request still works afterwards, which is the point.
    assert.deepEqual((await client.ping()).what, 'build');
    client.close();
  });
});

describe('parseControlRequest', () => {
  it('accepts the four operations', () => {
    assert.deepEqual(parseControlRequest('{"op":"ping","rid":1}'), { op: 'ping', rid: 1 });
    assert.deepEqual(parseControlRequest('{"op":"cancel","rid":2}'), { op: 'cancel', rid: 2 });
    assert.deepEqual(parseControlRequest('{"op":"attach","rid":3,"after":7}'), { op: 'attach', rid: 3, after: 7 });
    assert.deepEqual(parseControlRequest('{"op":"steer","rid":4,"text":"hi"}'), { op: 'steer', rid: 4, text: 'hi' });
  });

  it('refuses everything else at the boundary', () => {
    assert.throws(() => parseControlRequest('not json'), /malformed/);
    assert.throws(() => parseControlRequest('[]'), /JSON object/);
    assert.throws(() => parseControlRequest('{"op":"ping"}'), /rid/);
    assert.throws(() => parseControlRequest('{"op":"steer","rid":1,"text":"  "}'), /non-empty/);
    assert.throws(() => parseControlRequest('{"op":"attach","rid":1,"after":-1}'), /seq/);
    assert.throws(() => parseControlRequest('{"op":"nope","rid":1}'), /unknown control op/);
  });
});

function settle(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 60));
}
