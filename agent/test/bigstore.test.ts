import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { setTimeout } from 'node:timers/promises';
import {
  BigStore,
  MAX_CONVERSATION_TURNS,
  reconcile,
  repoSlug,
  transition,
  type BigSession,
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

/** A session with a worktree directory that really exists on disk. */
function built(): BigSession {
  const session = store.create(repo, 'connection-pool backoff');
  const path = store.worktreePathFor(repo, session.id);
  mkdirSync(join(path, '.git'), { recursive: true });
  session.worktree = { path, baseCommit: 'a'.repeat(40), baseBranch: 'main', createdAt: Date.now() };
  transition(session, 'building', 'test');
  store.save(session);
  return session;
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
    store.writeDiff(session, 'diff --git a/x b/x\n');
    store.save(session);
    assert.equal(session.diffBytes, Buffer.byteLength('diff --git a/x b/x\n'));
    assert.equal(store.readDiff(repo, session.id), 'diff --git a/x b/x\n');
    const record = readFileSync(join(store.dirFor(repo, session.id), 'session.json'), 'utf8');
    assert.ok(!record.includes('diff --git'), 'the record stays small enough to list cheaply');
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
    assert.deepEqual(reconcile(session, { worktreeExists: false, diffExists: false, running: false }), {
      changed: false,
      detached: false,
    });
    assert.equal(session.state, 'drafting');
  });

  it('sends a session whose worktree vanished back to drafting', () => {
    const session = built();
    session.blocks = [
      { id: 'b1', title: 't', files: [], hunkIds: ['h1.1'], substantial: true, rationale: '', state: 'open', reopened: false, signatures: ['s'] },
    ];
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, { worktreeExists: false, diffExists: true, running: false });
    assert.equal(result.changed, true);
    assert.equal(session.state, 'drafting');
    assert.equal(session.worktree, null);
    assert.deepEqual(session.blocks, []);
    assert.match(session.transitions[session.transitions.length - 1]?.note ?? '', /worktree is gone/);
  });

  it('never claims a review is ready without a captured diff', () => {
    const session = built();
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, { worktreeExists: true, diffExists: false, running: false });
    assert.equal(result.changed, true);
    assert.equal(session.state, 'building');
    assert.equal(session.diffCapturedAt, null);
    assert.equal(result.detached, true);
  });

  it('reports a build nobody is driving as detached, without rewriting it', () => {
    const session = built();
    const result = reconcile(session, { worktreeExists: true, diffExists: false, running: false });
    assert.deepEqual(result, { changed: false, detached: true });
    assert.equal(session.state, 'building');
  });

  it('is not detached while this sidecar is driving the build', () => {
    const session = built();
    const result = reconcile(session, { worktreeExists: true, diffExists: false, running: true });
    assert.deepEqual(result, { changed: false, detached: false });
  });

  it('leaves a reviewing session with its diff intact', () => {
    const session = built();
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, { worktreeExists: true, diffExists: true, running: false });
    assert.deepEqual(result, { changed: false, detached: false });
    assert.equal(session.state, 'reviewing');
  });
});
