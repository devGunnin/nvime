import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { hostname, tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { setTimeout } from 'node:timers/promises';
import {
  BigStore,
  LOCK_STALE_MS,
  MAX_CONVERSATION_TURNS,
  reconcile,
  repoSlug,
  transition,
  type BigSession,
  type Reality,
} from '../src/bigstore.js';
import { ProtocolError } from '../src/protocol.js';

let root = '';
let repo = '';
let store: BigStore;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'nvime-big-'));
  repo = join(root, 'repo');
  mkdirSync(repo, { recursive: true });
  store = new BigStore(join(root, 'store'));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** A session whose build clone really exists on disk. */
function built(): BigSession {
  const session = store.create(repo, 'connection-pool backoff');
  const path = store.worktreePathFor(repo, session.id);
  mkdirSync(join(path, '.git'), { recursive: true });
  session.worktree = { path, baseCommit: 'a'.repeat(40), baseBranch: 'main', createdAt: Date.now(), ready: true };
  transition(session, 'building', 'test');
  store.save(session);
  return session;
}

/** Reality with nothing live, overridden field by field. */
function reality(overrides: Partial<Reality>): Reality {
  return { worktreeExists: true, diffExists: false, running: false, heldElsewhere: false, ...overrides };
}

describe('BigStore', () => {
  it('creates a session in drafting with its first transition recorded', () => {
    const session = store.create(repo, '  add a --version flag  ');
    assert.equal(session.title, 'add a --version flag');
    assert.equal(session.state, 'drafting');
    assert.deepEqual(session.transitions.map((entry) => entry.state), ['drafting']);
    assert.equal(session.spec, null);
  });

  it('refuses a session with no title', () => {
    assert.throws(() => store.create(repo, '   '), ProtocolError);
  });

  it('reads back what it saved, and lists most recently touched first', async () => {
    const first = store.create(repo, 'one');
    const second = store.create(repo, 'two');
    // `save` stamps updatedAt, and Date.now() has millisecond resolution.
    await setTimeout(2);
    store.save(first);
    assert.deepEqual(store.list(repo).map((session) => session.id), [first.id, second.id]);
    assert.equal(store.read(repo, first.id)?.title, 'one');
  });

  it('keeps two repos with the same basename apart', () => {
    const other = join(root, 'nested', 'repo');
    mkdirSync(other, { recursive: true });
    store.create(repo, 'here');
    assert.notEqual(repoSlug(repo), repoSlug(other));
    assert.deepEqual(store.list(other), []);
  });

  it('refuses a session id that would escape the store directory', () => {
    for (const id of ['../../etc', 'a/b', '', 'A'.repeat(40), 'has-dash']) {
      assert.throws(() => store.dirFor(repo, id), ProtocolError, `accepted '${id}'`);
    }
  });

  it('treats a corrupt record as absent rather than refusing the whole picker', () => {
    const session = store.create(repo, 'broken');
    writeFileSync(join(store.dirFor(repo, session.id), 'session.json'), '{not json');
    assert.equal(store.read(repo, session.id), null);
    assert.deepEqual(store.list(repo), []);
    assert.throws(() => store.require(repo, session.id), ProtocolError);
  });

  it('holds the diff beside the record, not inside it', () => {
    const session = store.create(repo, 'diffed');
    const text = 'diff --git a/x b/x\n';
    const id = store.stageDiff(session, text);
    store.commitCapture(session, { id, bytes: Buffer.byteLength(text), blocks: [] });
    assert.equal(session.diffBytes, Buffer.byteLength(text));
    assert.equal(store.readDiff(repo, session.id), text);
    const record = readFileSync(join(store.dirFor(repo, session.id), 'session.json'), 'utf8');
    assert.ok(!record.includes('diff --git'), 'the record stays small enough to list cheaply');
  });

  it('disowns a staged diff until the blocks describing it are written too', () => {
    const session = store.create(repo, 'interrupted');
    store.stageDiff(session, 'diff --git a/x b/x\n');
    assert.equal(session.diffCapturedAt, null, 'staging alone never makes it the session\'s diff');
    assert.equal(store.hasDiff(session), false);
    assert.equal(store.readVerifiedDiff(session), null, 'nothing describes it yet, so nothing serves it');
  });

  it('refuses a diff on disk that is not the one the blocks were triaged against', () => {
    const session = store.create(repo, 'swapped');
    const text = 'diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n';
    store.commitCapture(session, { id: store.stageDiff(session, text), bytes: text.length, blocks: [] });
    assert.equal(store.readVerifiedDiff(session), text);
    // A later build's capture landing under an earlier build's record.
    writeFileSync(store.diffPathFor(repo, session.id), 'diff --git a/y b/y\n@@ -1 +1 @@\n-c\n+d\n');
    assert.equal(store.readVerifiedDiff(session), null, 'threads must never render hunks nobody triaged');
  });

  it('trims the conversation instead of growing it without bound', () => {
    const session = store.create(repo, 'chatty');
    for (let i = 0; i < MAX_CONVERSATION_TURNS + 10; i += 1) {
      session.conversation.push({ role: 'user', text: `m${i}`, at: i });
    }
    store.save(session);
    assert.equal(session.conversation.length, MAX_CONVERSATION_TURNS);
    assert.equal(session.conversation[0]?.text, 'm10');
  });

  it('destroys a session directory outright', () => {
    const session = built();
    store.destroy(repo, session.id);
    assert.equal(store.read(repo, session.id), null);
  });
});

describe('reconcile', () => {
  it('leaves a drafting session alone', () => {
    const session = store.create(repo, 'draft');
    assert.deepEqual(reconcile(session, reality({ worktreeExists: false })), {
      changed: false,
      detached: false,
      heldElsewhere: false,
    });
    assert.equal(session.state, 'drafting');
  });

  it('sends a session whose build clone vanished back to drafting', () => {
    const session = built();
    session.blocks = [
      { id: 'b1', title: 't', files: [], hunkIds: ['h1.1'], substantial: true, rationale: '', state: 'open', reopened: false, signatures: ['s'] },
    ];
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, reality({ worktreeExists: false, diffExists: true }));
    assert.equal(result.changed, true);
    assert.equal(session.state, 'drafting');
    assert.equal(session.worktree, null);
    assert.deepEqual(session.blocks, []);
    assert.match(session.transitions[session.transitions.length - 1]?.note ?? '', /clone is gone/);
  });

  it('sends a review with no captured diff back to triaging, not back to building', () => {
    const session = built();
    session.diffCapturedAt = Date.now();
    session.diffId = 'abc';
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, reality({}));
    assert.equal(result.changed, true);
    // The build is done; only the split is missing, so it is re-triaged rather
    // than sent back through the build agent.
    assert.equal(session.state, 'triaging');
    assert.equal(session.diffCapturedAt, null);
    assert.equal(session.diffId, null);
    assert.equal(result.detached, true);
  });

  it('leaves a triaging session with no diff alone — it renders no threads and is honest', () => {
    const session = built();
    transition(session, 'triaging', 'test');
    const result = reconcile(session, reality({}));
    assert.deepEqual(result, { changed: false, detached: true, heldElsewhere: false });
    assert.equal(session.state, 'triaging');
    assert.deepEqual(session.blocks, []);
  });

  it('does not call an approved-but-unbuilt clone "gone"', () => {
    const session = store.create(repo, 'approved');
    session.worktree = {
      path: store.worktreePathFor(repo, session.id),
      baseCommit: 'b'.repeat(40),
      baseBranch: 'main',
      createdAt: Date.now(),
      ready: false,
    };
    transition(session, 'building', 'approved');
    const result = reconcile(session, reality({ worktreeExists: false }));
    assert.equal(result.changed, false, 'the clone is made by the build, so its absence is expected');
    assert.equal(session.state, 'building');
    assert.notEqual(session.worktree, null);
  });

  it('reports a build nobody is driving as detached, without rewriting it', () => {
    const session = built();
    const result = reconcile(session, reality({}));
    assert.deepEqual(result, { changed: false, detached: true, heldElsewhere: false });
    assert.equal(session.state, 'building');
  });

  it('is not detached while another editor holds the session', () => {
    const session = built();
    const result = reconcile(session, reality({ heldElsewhere: true }));
    assert.deepEqual(result, { changed: false, detached: false, heldElsewhere: true });
  });

  it('is not detached while this sidecar is driving the build', () => {
    const session = built();
    const result = reconcile(session, reality({ running: true }));
    assert.deepEqual(result, { changed: false, detached: false, heldElsewhere: false });
  });

  it('leaves a reviewing session with its diff intact', () => {
    const session = built();
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, reality({ diffExists: true }));
    assert.deepEqual(result, { changed: false, detached: false, heldElsewhere: false });
    assert.equal(session.state, 'reviewing');
  });
});

describe('the cross-process run claim', () => {
  it('lets one handle claim a session and refuses the second', () => {
    const other = new BigStore(store.root);
    const session = built();
    const lock = store.acquireLock(session, 'build');
    assert.throws(
      () => other.acquireLock(session, 'build'),
      (error: unknown) => error instanceof ProtocolError && error.code === 'busy',
    );
    lock.release();
    other.acquireLock(session, 'build').release();
  });

  it('does not report this process\'s own claim as another editor\'s', () => {
    const session = built();
    const lock = store.acquireLock(session, 'build');
    assert.notEqual(store.readLock(session), null);
    assert.equal(store.foreignLock(session), null, 'our own run is not "somewhere else"');
    lock.release();
    assert.equal(store.readLock(session), null, 'releasing clears the claim');
  });

  it('sees a claim from another live process as held elsewhere', () => {
    const session = built();
    // process 1 always exists and is not us; the claim is fresh.
    writeFileSync(
      store.lockPathFor(repo, session.id),
      JSON.stringify({ pid: 1, host: hostname(), what: 'build', startedAt: Date.now(), heartbeatAt: Date.now() }),
    );
    assert.notEqual(store.foreignLock(session), null);
    assert.throws(() => store.acquireLock(session, 'build'), ProtocolError);
  });

  it('reclaims a claim whose holder stopped heartbeating', () => {
    const session = built();
    const stale = Date.now() - LOCK_STALE_MS - 1000;
    writeFileSync(
      store.lockPathFor(repo, session.id),
      JSON.stringify({ pid: 1, host: hostname(), what: 'build', startedAt: stale, heartbeatAt: stale }),
    );
    assert.equal(store.foreignLock(session), null, 'a dead sidecar must not wedge the session');
    store.acquireLock(session, 'build').release();
  });

  it('treats an unreadable claim as no claim rather than wedging the session', () => {
    const session = built();
    writeFileSync(store.lockPathFor(repo, session.id), '{not json');
    assert.equal(store.readLock(session), null);
    store.acquireLock(session, 'build').release();
  });
});
