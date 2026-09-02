import assert from 'node:assert/strict';
import { spawn, type ChildProcessByStdio } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { hostname, tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { setTimeout } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import {
  BigStore,
  clearCapture,
  diffIdOf,
  LOCK_HEARTBEAT_MS,
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
  session.base = { commit: 'a'.repeat(40), branch: 'main' };
  session.worktree = { path, createdAt: Date.now(), ready: true };
  transition(session, 'building', 'test');
  store.save(session);
  return session;
}

/** Reality with nothing live, overridden field by field. */
function reality(overrides: Partial<Reality>): Reality {
  return {
    worktreeExists: true,
    diffExists: false,
    diffVerified: false,
    running: false,
    heldElsewhere: false,
    ...overrides,
  };
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

  it('records custom managed thresholds without weakening validation', () => {
    const session = store.create(repo, 'managed review', 'medium', 82, 'org:42:policy:7');
    assert.equal(session.difficulty, 'medium');
    assert.equal(session.threshold, 82);
    assert.equal(session.policyId, 'org:42:policy:7');
    assert.throws(() => store.create(repo, 'too low', 'medium', 0), ProtocolError);
    assert.throws(() => store.create(repo, 'too high', 'medium', 101), ProtocolError);
    assert.throws(() => store.create(repo, 'not whole', 'medium', 70.5), ProtocolError);
    assert.throws(() => store.create(repo, 'vibe threshold', 'vibe', 40), ProtocolError);
    assert.throws(() => store.create(repo, 'bad policy', 'medium', 70, 'latest'), ProtocolError);
  });

  it('uses the complete SHA-256 digest as the portable diff identity', () => {
    const first = diffIdOf('diff --git a/a b/a\n');
    const second = diffIdOf('diff --git a/b b/b\n');
    assert.match(first, /^[a-f0-9]{64}$/);
    assert.notEqual(first, second);
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
      { id: 'b1', title: 't', files: [], hunkIds: ['h1.1'], substantial: true, rationale: '', state: 'open', reopened: false, signatures: ['s'], rounds: [] },
    ];
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, reality({ worktreeExists: false, diffExists: true }));
    assert.equal(result.changed, true);
    assert.equal(session.state, 'drafting');
    assert.equal(session.worktree, null);
    assert.deepEqual(session.blocks, []);
    assert.match(session.transitions[session.transitions.length - 1]?.note ?? '', /clone is gone/);
  });

  it('keeps a finished review when the clone is gone but the captured diff still verifies', () => {
    const session = built();
    session.blocks = [
      { id: 'b1', title: 't', files: [], hunkIds: ['h1.1'], substantial: true, rationale: '', state: 'open', reopened: false, signatures: ['s'], rounds: [] },
    ];
    session.diffId = 'abc';
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    const result = reconcile(session, reality({ worktreeExists: false, diffExists: true, diffVerified: true }));
    assert.equal(result.changed, true, 'the worktree and buildSessionId still had to be cleared');
    assert.equal(session.state, 'reviewing', 'the review itself is not thrown away');
    assert.equal(session.worktree, null, 'only the clone-dependent affordances go');
    assert.equal(session.blocks.length, 1, 'the triaged threads survive');
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

  it('lands a detached build in reviewing when its clone is gone but the diff verifies', () => {
    // The stuck case: a revision transitions to `building` while the previous
    // capture is still on the record. If the clone then vanishes, `building`
    // offers only resume (which needs the clone) and discard — with a complete,
    // verifying review sitting right there.
    const session = built();
    session.blocks = [
      {
        id: 'b1',
        title: 't',
        files: [],
        hunkIds: ['h1.1'],
        substantial: true,
        rationale: '',
        state: 'open',
        reopened: false,
        signatures: ['s'],
        rounds: [],
      },
    ];
    session.diffId = 'abc';
    session.diffCapturedAt = Date.now();
    transition(session, 'building', 'requested changes');

    const result = reconcile(session, reality({ worktreeExists: false, diffExists: true, diffVerified: true }));
    assert.equal(result.changed, true);
    assert.equal(session.state, 'reviewing');
    assert.equal(result.detached, false, 'there is nothing left running to be detached from');
    assert.equal(session.blocks.length, 1, 'the threads and the diff they describe survive');
    assert.match(session.transitions[session.transitions.length - 1]?.note ?? '', /reviewed diff is intact/);
  });

  it('keeps a merged session merged whatever the disk says', () => {
    const session = built();
    session.merge = { branch: 'nvime/big/x', commit: 'c'.repeat(40), baseBranch: 'main', at: Date.now() };
    transition(session, 'merged', 'landed');
    const result = reconcile(session, reality({ worktreeExists: false, diffExists: false }));
    assert.equal(result.changed, false);
    assert.equal(session.state, 'merged', 'a landed change cannot be un-landed by a missing clone');
    assert.notEqual(session.merge, null);
  });

  it('keeps the base commit when the clone goes but the review survives', () => {
    const session = built();
    session.diffId = 'abc';
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    reconcile(session, reality({ worktreeExists: false, diffExists: true, diffVerified: true }));
    assert.equal(session.worktree, null);
    assert.deepEqual(session.base, { commit: 'a'.repeat(40), branch: 'main' }, 'a diff with no base cannot be landed');
  });

  it('does not call an approved-but-unbuilt clone "gone"', () => {
    const session = store.create(repo, 'approved');
    session.base = { commit: 'b'.repeat(40), branch: 'main' };
    session.worktree = {
      path: store.worktreePathFor(repo, session.id),
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

describe('clearCapture', () => {
  it('disowns the capture but leaves landAttempt untouched — callers null it deliberately', () => {
    // clearCapture is called from both a genuine re-capture (big.ts's
    // #captureAndTriage, which nulls landAttempt itself right beside this
    // call) AND from `reconcile`, which runs unlocked and must never destroy
    // the one crash-recovery pin that lets a landed-but-unrecorded merge be
    // found again (P5 cold-review finding 3). clearCapture cannot tell which
    // caller it is, so it leaves the pin alone and trusts the caller.
    const session = built();
    session.diffId = 'abc';
    session.diffCapturedAt = Date.now();
    session.landAttempt = { branch: 'nvime/big/old', tree: 'f'.repeat(40) };
    clearCapture(session);
    assert.deepEqual(session.landAttempt, { branch: 'nvime/big/old', tree: 'f'.repeat(40) });
    assert.equal(session.diffId, null);
  });
});

describe('reconcile and the landAttempt crash-recovery pin', () => {
  it('preserves a pinned land attempt when repairing a reviewing record whose diff went missing', () => {
    // Reproduces the exact sequence from finding 3: `merge()` lands the
    // commit and pins `landAttempt` (bigstore.ts:628-632, saved successfully
    // as part of a still-`reviewing` record); `#afterLanding`'s own save then
    // fails (full disk, store directory removed under a live run — the case
    // it is written for). The on-disk record is left `reviewing`, its diff
    // gone, with the pin intact. The next unlocked read reconciles it — and
    // must NOT destroy the pin `#repairLandedRecord` needs to recognize the
    // landing as this session's own on the following merge attempt.
    const session = built();
    session.diffCapturedAt = Date.now();
    transition(session, 'reviewing', 'test');
    session.landAttempt = { branch: 'nvime/big/7', tree: 'a'.repeat(40) };
    store.save(session);

    const result = reconcile(session, reality({ diffExists: false }));

    assert.equal(result.changed, true);
    assert.equal(session.state, 'triaging', 'the diff being gone still re-triages');
    assert.deepEqual(
      session.landAttempt,
      { branch: 'nvime/big/7', tree: 'a'.repeat(40) },
      'an unlocked reconcile must never wipe the crash-recovery pin — only a genuine new capture may',
    );
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

  it('does not resurrect a claim that was reclaimed while its holder was wedged', async () => {
    // The exact sequence the compare-and-swap exists for: this handle claims
    // the session and then stops beating (a wedged sidecar); another editor
    // reclaims it as stale and starts building; this handle's timer comes back.
    const session = built();
    const lock = store.acquireLock(session, 'build');
    const path = store.lockPathFor(repo, session.id);

    const takeover = {
      owner: 'the-other-editor',
      pid: process.pid,
      host: hostname(),
      what: 'build',
      startedAt: Date.now(),
      heartbeatAt: Date.now(),
    };
    writeFileSync(path, JSON.stringify(takeover));

    // Long enough for at least one beat from the handle that lost the claim.
    await setTimeout(LOCK_HEARTBEAT_MS + 500);
    assert.equal(JSON.parse(readFileSync(path, 'utf8')).owner, 'the-other-editor', 'a lost claim is not rewritten');
    assert.notEqual(store.foreignLock(session), null, 'and the old holder sees the session as somebody else\'s');

    // Releasing a claim it no longer owns must not unlock their build either.
    lock.release();
    assert.equal(JSON.parse(readFileSync(path, 'utf8')).owner, 'the-other-editor');
  });
});

describe('holderOf', () => {
  it('reads the claim file exactly once — foreignLock + liveRunner used to each read it separately', () => {
    const session = built();
    session.runner = {
      pid: process.pid,
      socket: '/tmp/nvime-holderof-test.sock',
      log: store.logPathFor(repo, session.id),
      what: 'rebase',
      startedAt: Date.now(),
      token: 'tok',
    };
    store.save(session);
    const lock = store.acquireLock(session, 'rebase');

    // A fresh handle, the way the sidecar reads a session it does not own.
    const other = new BigStore(store.root);
    const reread = other.require(repo, session.id);
    let reads = 0;
    const originalReadLock = other.readLock.bind(other);
    other.readLock = (arg: BigSession) => {
      reads += 1;
      return originalReadLock(arg);
    };

    const held = other.holderOf(reread);
    assert.equal(reads, 1, 'holderOf must read the claim file exactly once, not once per helper it used to call');
    assert.deepEqual(held, { detached: true, what: 'rebase' }, 'the recorded runner ties the claim to this session');

    lock.release();
  });

  it('reports no holder for its own claim, and null once released', () => {
    const session = built();
    const lock = store.acquireLock(session, 'build');
    assert.equal(store.holderOf(session), null, 'our own run is not a holder to report');
    lock.release();
    assert.equal(store.holderOf(session), null, 'a released claim holds nothing');
  });
});

describe('stale takeover under real contention', () => {
  const LOCK_CONTENDER = fileURLToPath(new URL('./fixtures/lock-contender.ts', import.meta.url));
  const CONTENDER_TIMEOUT_MS = 10_000;
  // Bounded for CI, matching the merge-gate reviewer's own 40-trial harness
  // (which reproduced the bug in 25 of 40 trials over two real processes).
  const TRIALS = 12;

  interface Outcome {
    result: string;
    stolenImmediately?: boolean;
  }

  /**
   * A contender kept alive for the whole test: process-startup jitter
   * (hundreds of ms) dwarfs the race window this probes (microseconds), so
   * respawning per trial would almost never land two processes inside
   * `acquireLock` at the same instant. One persistent worker per contender,
   * fed one session id per trial, keeps that jitter out of the loop.
   */
  class Contender {
    readonly #child: ChildProcessByStdio<Writable, Readable, Readable>;
    readonly #lines: string[] = [];
    #waiting: ((line: string) => void) | null = null;
    stderr = '';

    constructor(storeRoot: string, repoRoot: string) {
      this.#child = spawn(process.execPath, ['--import', 'tsx', LOCK_CONTENDER, storeRoot, repoRoot], {
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      createInterface({ input: this.#child.stdout }).on('line', (line) => {
        if (this.#waiting !== null) {
          const resolve = this.#waiting;
          this.#waiting = null;
          resolve(line);
        } else {
          this.#lines.push(line);
        }
      });
      this.#child.stderr.on('data', (chunk: Buffer) => {
        this.stderr += chunk.toString('utf8');
      });
    }

    /** Sends one session id and waits for that trial's one-line JSON reply. */
    async race(sessionId: string): Promise<Outcome> {
      this.#child.stdin.write(`${sessionId}\n`);
      const next =
        this.#lines.length > 0
          ? Promise.resolve(this.#lines.shift() as string)
          : new Promise<string>((resolve) => {
              this.#waiting = resolve;
            });
      const line = await Promise.race([
        next,
        setTimeout(CONTENDER_TIMEOUT_MS).then((): never => {
          throw new Error(`lock contender did not answer within ${CONTENDER_TIMEOUT_MS}ms`);
        }),
      ]);
      return JSON.parse(line) as Outcome;
    }

    close(): void {
      this.#child.stdin.end();
    }
  }

  /** A stale ghost lock seeded exactly as a killed sidecar would leave one. */
  function seedGhostLock(sessionId: string): void {
    mkdirSync(store.dirFor(repo, sessionId), { recursive: true });
    const stale = Date.now() - LOCK_STALE_MS - 1000;
    writeFileSync(
      store.lockPathFor(repo, sessionId),
      JSON.stringify({ pid: 1, host: hostname(), what: 'ghost', startedAt: stale, heartbeatAt: stale }),
    );
  }

  it('never deletes a live claim, and never lets a reader observe a torn write, across many races', async () => {
    const a = new Contender(store.root, repo);
    const b = new Contender(store.root, repo);
    try {
      for (let trial = 0; trial < TRIALS; trial += 1) {
        const sessionId = `race${trial}`;
        seedGhostLock(sessionId);

        const [first, second] = await Promise.all([a.race(sessionId), b.race(sessionId)]);

        for (const outcome of [first, second]) {
          if (outcome.result !== 'acquired') continue;
          assert.equal(outcome.stolenImmediately, false, `trial ${trial}: the winner's claim was gone right after acquiring it`);
        }
      }
    } finally {
      a.close();
      b.close();
    }
    for (const contender of [a, b]) {
      assert.doesNotMatch(
        contender.stderr,
        /ignoring an unreadable big-change lock/,
        `a reader observed a half-written claim\n${contender.stderr}`,
      );
    }
  });
});
