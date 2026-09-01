import { createHash, randomBytes } from 'node:crypto';
import {
  existsSync,
  linkSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { homedir, hostname } from 'node:os';
import { basename, join } from 'node:path';
import { DEFAULT_DIFFICULTY, isDifficulty, type Difficulty } from './gate.js';
import { ProtocolError } from './protocol.js';
import type { TriageBlock } from './triage.js';

/**
 * Big-change sessions on disk, one directory per session:
 *
 *   <root>/<repo-slug>/<session-id>/session.json   the record
 *   <root>/<repo-slug>/<session-id>/diff.patch     the captured diff
 *   <root>/<repo-slug>/<session-id>/lock.json      who is driving it, if anyone
 *   <root>/<repo-slug>/<session-id>/wt/            the build's clone of the repo
 *
 * Outside the repo on purpose — a build tree inside the tree it is built from
 * would show up in its own diff. The diff lives beside the record rather than
 * inside it so listing sessions stays cheap when one of them holds megabytes.
 *
 * The store is shared by every Neovim the user has open on the machine, so
 * "who is driving this session" cannot live in one process's memory: the lock
 * file is what a second editor reads to know the build is not its to resume.
 */

export interface BigSpec {
  goal: string;
  scope: string[];
  approach: string;
  acceptance: string[];
  outOfScope: string[];
}

/**
 * Where a session is. `merged` is terminal: the change is in the operator's
 * branch and nothing may move it back. Two states deliberately absent:
 * `mergeable` is `reviewing` with nothing open, derived at read time so the two
 * cannot disagree; and there is no `discarded`, because discarding deletes the
 * record rather than leaving a tombstone that every reader has to special-case.
 */
export type BigState = 'drafting' | 'building' | 'triaging' | 'reviewing' | 'merged';

/** What a completed local merge left behind, for the record and the report. */
export interface BigMerge {
  /** The branch nvime created at the base commit and landed. */
  branch: string;
  /** The commit holding the reviewed diff. */
  commit: string;
  /** The branch it was fast-forwarded into. */
  baseBranch: string;
  at: number;
}

export interface BigTransition {
  state: BigState;
  at: number;
  note: string;
}

/**
 * What THIS session's own land is expected to look like, pinned on the record
 * before `landDiff` runs and never guessed from the title afterward. Lets a
 * repair recognize its own unrecorded landing by branch AND content, so a
 * sibling session's identically-titled change — or any other commit that
 * happens to sit under the same name — can never be claimed as this one's.
 */
export interface BigLandAttempt {
  branch: string;
  /** The tree the reviewed diff applies to at the pinned base commit. */
  tree: string;
}

/**
 * What the change is built on. A property of the CHANGE, not of the clone: the
 * clone is disposable and the reviewed diff outlives it, but a diff without the
 * commit it applies to cannot be landed at all.
 */
export interface BigBase {
  commit: string;
  /** The branch HEAD was on, or null when the repo was already detached. */
  branch: string | null;
}

export interface BigWorktree {
  path: string;
  createdAt: number;
  /**
   * False between approval and the clone that `build` makes. It separates
   * "the clone has not been made yet" from "the clone was made and is gone",
   * which look identical on disk and mean opposite things.
   */
  ready: boolean;
}

export interface BigTurn {
  role: 'user' | 'agent';
  text: string;
  at: number;
}

/**
 * The detached process driving this session's build, while one is driving it.
 *
 * Written by the runner itself, under the same run claim as everything else it
 * writes, and cleared when it finishes. A record that still names a runner
 * whose claim has gone stale is exactly how "the build died" is told apart from
 * "the build is running" — nothing here is guessed from a pid alone.
 */
export interface BigRunner {
  pid: number;
  /** The control socket. Derived, not authoritative: recorded for diagnosis. */
  socket: string;
  /** The append-only event log this run is writing. */
  log: string;
  /** `build`, `revise`, or `rebase`. */
  what: string;
  startedAt: number;
}

export interface BigSession {
  version: 1;
  id: string;
  repoRoot: string;
  title: string;
  state: BigState;
  /** How hard the comprehension gate is. Chosen at intake, fixed after. */
  difficulty: Difficulty;
  createdAt: number;
  updatedAt: number;
  transitions: BigTransition[];
  conversation: BigTurn[];
  spec: BigSpec | null;
  approvedAt: number | null;
  /** SDK session driving intake, and the one driving the build. Kept apart:
   *  the build agent must not inherit intake's read-only history as licence. */
  intakeSessionId: string | null;
  buildSessionId: string | null;
  /** The grader's own session, so a follow-up round remembers the last one. */
  gradeSessionId: string | null;
  /** Recorded at approval, moved by a rebase. Outlives the clone. */
  base: BigBase | null;
  worktree: BigWorktree | null;
  /** The detached runner driving the build, or null when none is recorded. */
  runner: BigRunner | null;
  /** Set once, when the change landed. Null for everything not yet merged. */
  merge: BigMerge | null;
  /** Pinned right before the current or most recent land attempt. Null before
   *  the first one, and stale-but-harmless after a rebase moves the base. */
  landAttempt: BigLandAttempt | null;
  /**
   * Identity of the diff `blocks` describe, written in the same record write
   * as they are. `diff.patch` on disk that hashes to something else is a diff
   * these blocks were never triaged against, and is refused rather than shown.
   */
  diffId: string | null;
  diffCapturedAt: number | null;
  diffBytes: number;
  blocks: TriageBlock[];
}

/** Session ids index a directory, so the charset is a boundary check. */
const SESSION_ID = /^[a-z0-9]{1,32}$/;

/** A lock whose heartbeat is older than this is treated as abandoned. */
export const LOCK_STALE_MS = 15_000;

/** How often the holder proves it is still there. Well under the stale bound. */
export const LOCK_HEARTBEAT_MS = 3_000;

/** Conversation kept per session; older turns fall off rather than grow forever. */
export const MAX_CONVERSATION_TURNS = 200;

export function defaultBigRoot(env: Record<string, string | undefined>): string {
  const base = env.XDG_DATA_HOME ?? join(homedir(), '.local', 'share');
  return join(base, 'nvime', 'big');
}

/** Stable, readable directory name for a repo. The hash keeps two `api` apart. */
export function repoSlug(repoRoot: string): string {
  const name = basename(repoRoot).replace(/[^A-Za-z0-9._-]/g, '-') || 'repo';
  const hash = createHash('sha256').update(repoRoot).digest('hex').slice(0, 8);
  return `${name}-${hash}`;
}

export class BigStore {
  readonly #root: string;
  /**
   * Who this handle is, for the run claim. Identity is the HANDLE, not the
   * process: one sidecar owns exactly one store, and two handles are two
   * independent claimants whether or not they share a process.
   */
  readonly #owner: string = randomBytes(8).toString('hex');

  constructor(root: string) {
    if (root === '') throw new TypeError('BigStore needs a root directory');
    this.#root = root;
  }

  get root(): string {
    return this.#root;
  }

  dirFor(repoRoot: string, id: string): string {
    return join(this.#root, repoSlug(repoRoot), requireId(id));
  }

  worktreePathFor(repoRoot: string, id: string): string {
    return join(this.dirFor(repoRoot, id), 'wt');
  }

  diffPathFor(repoRoot: string, id: string): string {
    return join(this.dirFor(repoRoot, id), 'diff.patch');
  }

  lockPathFor(repoRoot: string, id: string): string {
    return join(this.dirFor(repoRoot, id), 'lock.json');
  }

  /** The session's append-only build log. Survives every run, and is replayed. */
  logPathFor(repoRoot: string, id: string): string {
    return join(this.dirFor(repoRoot, id), 'events.ndjson');
  }

  create(repoRoot: string, title: string, difficulty: Difficulty = DEFAULT_DIFFICULTY): BigSession {
    if (title.trim() === '') throw new ProtocolError('bad_request', 'a big change needs a title');
    const now = Date.now();
    const session: BigSession = {
      version: 1,
      id: newId(),
      repoRoot,
      title: title.trim().slice(0, 120),
      state: 'drafting',
      difficulty,
      createdAt: now,
      updatedAt: now,
      transitions: [{ state: 'drafting', at: now, note: 'created' }],
      conversation: [],
      spec: null,
      approvedAt: null,
      intakeSessionId: null,
      buildSessionId: null,
      gradeSessionId: null,
      base: null,
      worktree: null,
      runner: null,
      merge: null,
      landAttempt: null,
      diffId: null,
      diffCapturedAt: null,
      diffBytes: 0,
      blocks: [],
    };
    this.save(session);
    return session;
  }

  /** Every session recorded for this repo, newest first. Unreadable ones are skipped loudly. */
  list(repoRoot: string): BigSession[] {
    const dir = join(this.#root, repoSlug(repoRoot));
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT' && code !== 'ENOTDIR') {
        process.stderr.write(`nvime: cannot list big sessions in ${dir}: ${String(cause)}\n`);
      }
      return [];
    }
    const sessions: BigSession[] = [];
    for (const entry of entries) {
      if (!SESSION_ID.test(entry)) continue;
      const session = this.read(repoRoot, entry);
      if (session !== null) sessions.push(session);
    }
    return sessions.sort((a, b) => b.updatedAt - a.updatedAt);
  }

  /**
   * One session, or null when it is absent or unreadable. A corrupt record is
   * reported on stderr and treated as absent: refusing to open the picker
   * because one session's file is broken helps nobody.
   */
  read(repoRoot: string, id: string): BigSession | null {
    const path = join(this.dirFor(repoRoot, id), 'session.json');
    let text: string;
    try {
      text = readFileSync(path, 'utf8');
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT' && code !== 'ENOTDIR') {
        process.stderr.write(`nvime: cannot read ${path}: ${String(cause)}\n`);
      }
      return null;
    }
    try {
      const parsed = JSON.parse(text) as BigSession;
      if (parsed.version !== 1 || parsed.id !== id) throw new Error('unexpected shape');
      return withDefaults(parsed);
    } catch (cause) {
      process.stderr.write(`nvime: ignoring corrupt big session ${path}: ${String(cause)}\n`);
      return null;
    }
  }

  /** The session, or a `bad_request` naming the id the editor asked for. */
  require(repoRoot: string, id: string): BigSession {
    const session = this.read(repoRoot, id);
    if (session === null) throw new ProtocolError('bad_request', `no big change '${id}' in this project`);
    return session;
  }

  save(session: BigSession): void {
    session.updatedAt = Date.now();
    if (session.conversation.length > MAX_CONVERSATION_TURNS) {
      session.conversation = session.conversation.slice(-MAX_CONVERSATION_TURNS);
    }
    const dir = this.dirFor(session.repoRoot, session.id);
    mkdirSync(dir, { recursive: true });
    writeAtomic(join(dir, 'session.json'), JSON.stringify(session, null, 2));
  }

  /**
   * Puts the captured text on disk and returns its identity. The RECORD still
   * disowns it: only `commitCapture` makes it the session's diff, so a failure
   * during triage leaves a session with no threads rather than threads that
   * describe an older build.
   */
  stageDiff(session: BigSession, diff: string): string {
    const dir = this.dirFor(session.repoRoot, session.id);
    mkdirSync(dir, { recursive: true });
    writeAtomic(join(dir, 'diff.patch'), diff);
    return diffIdOf(diff);
  }

  /**
   * The diff's identity and the blocks describing it, in ONE record write.
   * They are a single fact — "this is the change, split up this way" — and a
   * record that carried half of it would render one build's threads over
   * another build's hunks.
   */
  commitCapture(session: BigSession, capture: { id: string; bytes: number; blocks: TriageBlock[] }): void {
    session.diffId = capture.id;
    session.diffCapturedAt = Date.now();
    session.diffBytes = capture.bytes;
    session.blocks = capture.blocks;
    this.save(session);
  }

  readDiff(repoRoot: string, id: string): string | null {
    try {
      return readFileSync(this.diffPathFor(repoRoot, id), 'utf8');
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT' && code !== 'ENOTDIR') {
        process.stderr.write(`nvime: cannot read the captured diff for ${id}: ${String(cause)}\n`);
      }
      return null;
    }
  }

  /**
   * The captured diff, but only when it is the one this session's blocks were
   * triaged against. Serving any other text would show a reviewer hunks nobody
   * sorted into the threads they are reading.
   */
  readVerifiedDiff(session: BigSession): string | null {
    if (session.diffCapturedAt === null || session.diffId === null) return null;
    const text = this.readDiff(session.repoRoot, session.id);
    if (text === null) return null;
    if (diffIdOf(text) !== session.diffId) {
      process.stderr.write(`nvime: the captured diff for ${session.id} is not the one its threads describe\n`);
      return null;
    }
    return text;
  }

  /** Deletes the whole session directory. The worktree must already be gone. */
  destroy(repoRoot: string, id: string): void {
    rmSync(this.dirFor(repoRoot, id), { recursive: true, force: true });
  }

  /** True when the build's clone is really on disk (a clone with no `.git` is gone). */
  hasWorktree(session: BigSession): boolean {
    return session.worktree !== null && existsSync(join(session.worktree.path, '.git'));
  }

  hasDiff(session: BigSession): boolean {
    return session.diffCapturedAt !== null && existsSync(this.diffPathFor(session.repoRoot, session.id));
  }

  // ---- the cross-process run claim -----------------------------------------

  /** Whoever last claimed this session, live or not, or null when nobody has. */
  readLock(session: BigSession): BigLock | null {
    return readLockAt(this.lockPathFor(session.repoRoot, session.id));
  }

  /**
   * A live claim held by someone else — another editor is driving this session,
   * so it is read-only here and neither resumable nor discardable.
   */
  foreignLock(session: BigSession): BigLock | null {
    const lock = this.readLock(session);
    if (lock === null || !isLockLive(lock)) return null;
    return lock.owner === this.#owner ? null : lock;
  }

  /**
   * Claims the session for one run. Exclusive creation decides the race; a
   * claim whose holder stopped heartbeating (a killed sidecar) is reclaimed by
   * compare-and-delete — only the exact stale file just observed is removed —
   * which is what keeps a crash from wedging the session forever without ever
   * deleting a claim a faster contender has since written in its place.
   *
   * @throws ProtocolError `busy` when another live run holds it.
   */
  acquireLock(session: BigSession, what: string): SessionLock {
    const path = this.lockPathFor(session.repoRoot, session.id);
    mkdirSync(this.dirFor(session.repoRoot, session.id), { recursive: true });
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const claim: BigLock = {
        owner: this.#owner,
        pid: process.pid,
        host: hostname(),
        what,
        startedAt: Date.now(),
        heartbeatAt: Date.now(),
      };
      if (tryClaim(path, claim)) return confirmClaim(path, claim);
      const observed = statLockAt(path);
      if (observed !== null && observed.lock !== null && isLockLive(observed.lock)) {
        throw new ProtocolError('busy', `this big change is running in another editor (${observed.lock.what})`);
      }
      // Abandoned, or released between the two calls: remove only the exact
      // file just observed stale, so a slower contender can never delete a
      // fresher claim a faster one has since written to the same path.
      if (observed !== null) removeIfUnchanged(path, observed.ino);
    }
    throw new ProtocolError('busy', 'this big change is being claimed by another editor');
  }
}

/** One store handle's claim on a session, refreshed until it is released. */
export interface BigLock {
  /** The claiming handle. Two editors never share one. */
  owner: string;
  /** For liveness only: a claim from a dead process is reclaimable at once. */
  pid: number;
  host: string;
  /** What the holder is doing, so the other editor can say so. */
  what: string;
  startedAt: number;
  heartbeatAt: number;
}

export interface SessionLock {
  release(): void;
}

function readLockAt(path: string): BigLock | null {
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') {
      process.stderr.write(`nvime: cannot read ${path}: ${String(cause)}\n`);
    }
    return null;
  }
  try {
    const lock = JSON.parse(text) as BigLock;
    if (typeof lock.pid !== 'number' || typeof lock.heartbeatAt !== 'number') throw new Error('unexpected shape');
    return lock;
  } catch (cause) {
    process.stderr.write(`nvime: ignoring an unreadable big-change lock ${path}: ${String(cause)}\n`);
    return null;
  }
}

/**
 * True when this process took the claim; false when someone already holds it.
 *
 * The full claim is written to a private tmp file first and then linked into
 * place. `linkSync` is exclusive exactly like `wx` (`EEXIST` when the target
 * already exists), but — unlike open-then-write — there is no window where a
 * reader can see the path half-written: it either does not exist yet, or it
 * already has its complete content, because the content was on disk before
 * the name that makes it visible ever existed.
 */
function tryClaim(path: string, claim: BigLock): boolean {
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  writeFileSync(tmp, JSON.stringify(claim), { mode: 0o600 });
  try {
    linkSync(tmp, path);
    return true;
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === 'EEXIST') return false;
    throw cause;
  } finally {
    // Only the tmp file's own directory entry goes; `path`'s hard link (if
    // the link above succeeded) keeps the same inode and content alive.
    rmSync(tmp, { force: true });
  }
}

/** A lock path's inode, and its content when that content is readable. */
interface StatLock {
  /** Null for a lock file that exists but does not parse — corrupt, not absent. */
  lock: BigLock | null;
  ino: number;
}

/**
 * Like `readLockAt`, but also names the inode a compare-and-delete needs, and
 * tells "the path is absent" (null) apart from "the path is there but
 * unreadable" (`lock: null` with a real `ino`) — the latter is exactly as
 * reclaimable as a stale claim, and must not be mistaken for nothing to do.
 */
function statLockAt(path: string): StatLock | null {
  let ino: number;
  try {
    ino = statSync(path).ino;
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
    return null;
  }
  return { lock: readLockAt(path), ino };
}

/**
 * Compare-and-delete: unlinks `path` only when it is still the exact inode
 * observed stale. A contender racing a faster one that already reclaimed and
 * rewrote the same path finds a different inode here and leaves it alone,
 * instead of deleting the live claim that faster contender just wrote.
 */
function removeIfUnchanged(path: string, expectedIno: number): void {
  try {
    if (statSync(path).ino !== expectedIno) return;
    unlinkSync(path);
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
  }
}

/**
 * The last line of defence: even a claim this process believes it just won
 * must be re-read before it is trusted, so a takeover this process lost by a
 * hair is discovered here rather than by a build running unlocked.
 */
function confirmClaim(path: string, claim: BigLock): SessionLock {
  const held = readLockAt(path);
  if (held === null || held.owner !== claim.owner) {
    throw new ProtocolError('busy', 'this big change is being claimed by another editor');
  }
  return heartbeat(path, claim);
}

/**
 * Refreshes the claim until it is released — but only while it is still OURS.
 *
 * The compare is the point. A run this process was too wedged to heartbeat is
 * reclaimed as stale by another editor, which then owns the session; a beat
 * that arrived afterwards and wrote unconditionally would resurrect the dead
 * claim over the live one and hand two editors the same build clone. So each
 * beat re-reads the file first and stops the moment the owner is not us.
 *
 * The read and the write are not one atomic step, and cannot be: `rename` takes
 * no expected-inode. The residual window is a takeover landing between them,
 * which needs this beat to be 15s stale (why it was reclaimed) and running now.
 */
function heartbeat(path: string, claim: BigLock): SessionLock {
  const timer = setInterval(() => {
    const held = readLockAt(path);
    if (held === null || held.owner !== claim.owner) {
      process.stderr.write(`nvime: the big-change lock ${path} is no longer ours — not refreshing it\n`);
      clearInterval(timer);
      return;
    }
    // Atomic: a reader must never see a half-written claim and mistake it for
    // an abandoned one, which would hand a second editor the same session.
    try {
      writeAtomic(path, JSON.stringify({ ...claim, heartbeatAt: Date.now() }));
    } catch (cause) {
      // The session directory went away under a live run — a discard from
      // elsewhere. Say so and stop; the run itself will fail on its own work.
      process.stderr.write(`nvime: lost the big-change lock ${path}: ${String(cause)}\n`);
      clearInterval(timer);
    }
  }, LOCK_HEARTBEAT_MS);
  // The sidecar must still be able to exit while a lock is held.
  timer.unref();
  return {
    release: () => {
      clearInterval(timer);
      // Only ours: a claim reclaimed as stale while this run was wedged now
      // belongs to another editor, and deleting it would unlock their build.
      const held = readLockAt(path);
      if (held === null || held.owner === claim.owner) rmSync(path, { force: true });
    },
  };
}

/**
 * Whether a claim still has someone behind it. The heartbeat is the authority
 * — it is the only signal that works across machines. A dead pid on THIS host
 * is checked too, so a killed sidecar's session is usable again immediately
 * instead of after the stale window.
 */
export function isLockLive(lock: BigLock): boolean {
  if (Date.now() - lock.heartbeatAt > LOCK_STALE_MS) return false;
  if (lock.host !== hostname()) return true;
  return isPidAlive(lock.pid);
}

function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (cause) {
    // EPERM means it exists and belongs to someone else; ESRCH means it is gone.
    return (cause as NodeJS.ErrnoException).code === 'EPERM';
  }
}

function writeAtomic(path: string, text: string): void {
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text, { mode: 0o600 });
  renameSync(tmp, path);
}

function newId(): string {
  return Date.now().toString(36) + randomBytes(3).toString('hex');
}

/**
 * Fills in the fields a record written by an earlier sidecar does not carry.
 * The gate's difficulty is the reason this exists: an absent value would read
 * as "no threshold", which is `vibe` — a silently disarmed gate on a session
 * the reader believes is gated.
 */
function withDefaults(session: BigSession): BigSession {
  if (!isDifficulty(session.difficulty)) session.difficulty = DEFAULT_DIFFICULTY;
  if (session.gradeSessionId === undefined) session.gradeSessionId = null;
  if (session.merge === undefined) session.merge = null;
  if (session.landAttempt === undefined) session.landAttempt = null;
  // A record written before detached builds existed has no runner, which is
  // the same thing as never having had one: nothing is driving it.
  if (session.runner === undefined) session.runner = null;
  // The base used to live on the worktree, before it had to outlive the clone.
  const legacy = session.worktree as unknown as { baseCommit?: string; baseBranch?: string | null } | null;
  if (session.base == null && legacy?.baseCommit !== undefined) {
    session.base = { commit: legacy.baseCommit, branch: legacy.baseBranch ?? null };
  }
  if (session.base === undefined) session.base = null;
  for (const block of session.blocks) {
    if (!Array.isArray(block.rounds)) block.rounds = [];
  }
  return session;
}

/** Identity of a captured diff: the same bytes, the same id, always. */
export function diffIdOf(diff: string): string {
  return createHash('sha256').update(diff, 'utf8').digest('hex').slice(0, 32);
}

/**
 * Disowns the capture and everything derived from it, in one place. Does NOT
 * touch `landAttempt` — `reconcile` also calls this, outside the run lock, to
 * repair a `reviewing` record whose diff went missing, and `landAttempt` is
 * the one thing crash recovery needs surviving that repair. Callers that are
 * genuinely re-capturing (a new triage, a rebase) null it themselves.
 */
export function clearCapture(session: BigSession): void {
  session.blocks = [];
  session.diffId = null;
  session.diffCapturedAt = null;
  session.diffBytes = 0;
}

function requireId(id: string): string {
  if (!SESSION_ID.test(id)) throw new ProtocolError('bad_request', `'${id}' is not a big-change id`);
  return id;
}

/** Records a state change with its timestamp. Every transition is on the record. */
export function transition(session: BigSession, state: BigState, note: string): void {
  session.state = state;
  session.transitions.push({ state, at: Date.now(), note });
}

export interface Reality {
  worktreeExists: boolean;
  diffExists: boolean;
  /**
   * Whether the captured diff on disk still hashes to what the session's
   * blocks were triaged against — stronger than `diffExists`, which only
   * checks the file is there. A finished review is only ever kept on this.
   */
  diffVerified: boolean;
  /** Whether THIS sidecar is driving the session right now. */
  running: boolean;
  /** Whether another process holds a live claim on it. */
  heldElsewhere: boolean;
}

export interface Reconciled {
  /** True when the record was corrected and must be written back. */
  changed: boolean;
  /** A build or triage the record claims, that no live run anywhere is behind. */
  detached: boolean;
  /** Another editor is driving it: read-only here, and not ours to resume. */
  heldElsewhere: boolean;
}

/**
 * Makes the record agree with the disk. A session is only ever claimed to be
 * further along than the evidence supports if this function has a bug:
 *
 *   * merged                             → terminal; the change is in the
 *     operator's branch and no disk state can take it back.
 *   * the clone is gone, diff unverified → nothing trustworthy to review;
 *     back to drafting.
 *   * the clone is gone, diff verified   → the finished review survives; only
 *     the clone-dependent actions (revise, open-file) go away with it, and a
 *     build or triage that was in flight lands in `reviewing`, because the
 *     verified diff IS the finished capture and there is nothing left to run.
 *   * reviewing, no diff                 → nothing to review; back to triaging.
 *   * building, nothing live             → still building, but nobody is
 *     driving it.
 *
 * `triaging` with no captured diff is honest rather than wrong: the build is
 * done and the split is not, so it renders no threads and is re-triaged, not
 * rebuilt.
 */
export function reconcile(session: BigSession, reality: Reality): Reconciled {
  const live = reality.running || reality.heldElsewhere;
  const held = reality.heldElsewhere;
  if (session.state === 'drafting' || session.state === 'merged') {
    return { changed: false, detached: false, heldElsewhere: held };
  }
  // An approved session whose clone `build` has not made yet: its absence from
  // disk is expected, not evidence that a build was lost.
  const pending = session.worktree !== null && !session.worktree.ready;
  if (!pending && !reality.worktreeExists) {
    if (reality.diffVerified) {
      // Only reading needs the clone; a captured diff that still verifies is
      // a complete, self-consistent record of the change on its own. Drop the
      // clone-dependent affordances, but keep the review itself intact.
      let changed = session.worktree !== null || session.buildSessionId !== null;
      session.worktree = null;
      session.buildSessionId = null;
      // A `building`/`triaging` record here would otherwise be stuck: both
      // offer only "resume" and "discard", and resuming needs the clone that
      // is gone. The threads and the diff they describe are right there.
      if (session.state !== 'reviewing') {
        transition(session, 'reviewing', 'the build clone is gone, but its reviewed diff is intact');
        changed = true;
      }
      return { changed, detached: false, heldElsewhere: held };
    }
    transition(session, 'drafting', 'the build clone is gone — approve again to rebuild');
    session.worktree = null;
    session.buildSessionId = null;
    // Approving again reads HEAD afresh; a base left over from the lost build
    // would describe a commit nothing here is built on any more.
    session.base = null;
    clearCapture(session);
    return { changed: true, detached: false, heldElsewhere: held };
  }
  if (session.state === 'reviewing' && !reality.diffExists) {
    transition(session, 'triaging', 'no captured diff — the triage did not finish');
    clearCapture(session);
    return { changed: true, detached: !live, heldElsewhere: held };
  }
  const detached = !live && (session.state === 'building' || session.state === 'triaging');
  return { changed: false, detached, heldElsewhere: held };
}
