import { createHash, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { ProtocolError } from './protocol.js';
import type { TriageBlock } from './triage.js';

/**
 * Big-change sessions on disk, one directory per session:
 *
 *   <root>/<repo-slug>/<session-id>/session.json   the record
 *   <root>/<repo-slug>/<session-id>/diff.patch     the captured diff
 *   <root>/<repo-slug>/<session-id>/wt/            the build worktree
 *
 * Outside the repo on purpose — a worktree inside the tree it is built from
 * would show up in its own diff. The diff lives beside the record rather than
 * inside it so listing sessions stays cheap when one of them holds megabytes.
 */

export interface BigSpec {
  goal: string;
  scope: string[];
  approach: string;
  acceptance: string[];
  outOfScope: string[];
}

/**
 * Where a session is. Two states deliberately absent: `mergeable` is
 * `reviewing` with nothing open, derived at read time so the two cannot
 * disagree; and there is no `discarded`, because discarding deletes the record
 * rather than leaving a tombstone that every reader has to special-case.
 */
export type BigState = 'drafting' | 'building' | 'triaging' | 'reviewing';

export interface BigTransition {
  state: BigState;
  at: number;
  note: string;
}

export interface BigWorktree {
  path: string;
  baseCommit: string;
  baseBranch: string | null;
  createdAt: number;
}

export interface BigTurn {
  role: 'user' | 'agent';
  text: string;
  at: number;
}

export interface BigSession {
  version: 1;
  id: string;
  repoRoot: string;
  title: string;
  state: BigState;
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
  worktree: BigWorktree | null;
  diffCapturedAt: number | null;
  diffBytes: number;
  blocks: TriageBlock[];
}

/** Session ids index a directory, so the charset is a boundary check. */
const SESSION_ID = /^[a-z0-9]{1,32}$/;

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

  create(repoRoot: string, title: string): BigSession {
    if (title.trim() === '') throw new ProtocolError('bad_request', 'a big change needs a title');
    const now = Date.now();
    const session: BigSession = {
      version: 1,
      id: newId(),
      repoRoot,
      title: title.trim().slice(0, 120),
      state: 'drafting',
      createdAt: now,
      updatedAt: now,
      transitions: [{ state: 'drafting', at: now, note: 'created' }],
      conversation: [],
      spec: null,
      approvedAt: null,
      intakeSessionId: null,
      buildSessionId: null,
      worktree: null,
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
      return parsed;
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

  writeDiff(session: BigSession, diff: string): void {
    const dir = this.dirFor(session.repoRoot, session.id);
    mkdirSync(dir, { recursive: true });
    writeAtomic(join(dir, 'diff.patch'), diff);
    session.diffCapturedAt = Date.now();
    session.diffBytes = Buffer.byteLength(diff, 'utf8');
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

  /** Deletes the whole session directory. The worktree must already be gone. */
  destroy(repoRoot: string, id: string): void {
    rmSync(this.dirFor(repoRoot, id), { recursive: true, force: true });
  }

  hasWorktree(session: BigSession): boolean {
    return session.worktree !== null && existsSync(join(session.worktree.path, '.git'));
  }

  hasDiff(session: BigSession): boolean {
    return session.diffCapturedAt !== null && existsSync(this.diffPathFor(session.repoRoot, session.id));
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
  /** Whether THIS sidecar is driving the session right now. */
  running: boolean;
}

export interface Reconciled {
  /** True when the record was corrected and must be written back. */
  changed: boolean;
  /** A build or triage the record claims, that no live run is behind. */
  detached: boolean;
}

/**
 * Makes the record agree with the disk. A session is only ever claimed to be
 * further along than the evidence supports if this function has a bug:
 *
 *   * the worktree is gone   → nothing was built; back to drafting.
 *   * no captured diff       → nothing to review; back to building.
 *   * building, nothing live → still building, but nobody is driving it.
 */
export function reconcile(session: BigSession, reality: Reality): Reconciled {
  if (session.state === 'drafting') return { changed: false, detached: false };
  if (!reality.worktreeExists) {
    transition(session, 'drafting', 'the build worktree is gone — approve again to rebuild');
    session.worktree = null;
    session.buildSessionId = null;
    session.blocks = [];
    session.diffCapturedAt = null;
    session.diffBytes = 0;
    return { changed: true, detached: false };
  }
  if ((session.state === 'reviewing' || session.state === 'triaging') && !reality.diffExists) {
    transition(session, 'building', 'no captured diff — the build did not finish');
    session.blocks = [];
    session.diffCapturedAt = null;
    session.diffBytes = 0;
    return { changed: true, detached: !reality.running };
  }
  const detached = !reality.running && (session.state === 'building' || session.state === 'triaging');
  return { changed: false, detached };
}
