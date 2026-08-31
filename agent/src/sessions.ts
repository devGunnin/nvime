import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

/**
 * Which chat sessions belong to nvime, per project root. The SDK's session
 * store stays the source of truth for a session's title and age; this file
 * only records which of those sessions nvime created, so the picker never
 * offers the user's unrelated interactive Claude Code sessions.
 */
export interface ProjectSessions {
  current: string | null;
  known: string[];
}

interface StoreFile {
  version: 1;
  projects: Record<string, ProjectSessions>;
}

/** Older ids fall off the end; the picker only ever shows a recent window. */
export const MAX_KNOWN_PER_PROJECT = 50;

const EMPTY: ProjectSessions = { current: null, known: [] };

export function defaultStorePath(env: Record<string, string | undefined>): string {
  const base = env.XDG_DATA_HOME ?? join(homedir(), '.local', 'share');
  return join(base, 'nvime', 'sessions.json');
}

export class SessionStore {
  readonly #path: string;
  #file: StoreFile;

  constructor(path: string) {
    this.#path = path;
    this.#file = readStore(path);
  }

  get path(): string {
    return this.#path;
  }

  get(root: string): ProjectSessions {
    const entry = this.#file.projects[root];
    if (entry === undefined) return { ...EMPTY, known: [] };
    return { current: entry.current, known: [...entry.known] };
  }

  /** Records `sessionId` as the project's current session, most recent first. */
  remember(root: string, sessionId: string): void {
    if (root === '' || sessionId === '') {
      throw new Error('remember requires a non-empty root and session id');
    }
    const entry = this.#file.projects[root] ?? { current: null, known: [] };
    const known = [sessionId, ...entry.known.filter((id) => id !== sessionId)];
    known.length = Math.min(known.length, MAX_KNOWN_PER_PROJECT);
    this.#file.projects[root] = { current: sessionId, known };
    this.#persist();
  }

  /** Drops ids the SDK no longer knows about, so the picker stays truthful. */
  retain(root: string, liveIds: ReadonlySet<string>): void {
    const entry = this.#file.projects[root];
    if (entry === undefined) return;
    const known = entry.known.filter((id) => liveIds.has(id));
    if (known.length === entry.known.length) return;
    const current = entry.current !== null && liveIds.has(entry.current) ? entry.current : null;
    this.#file.projects[root] = { current, known };
    this.#persist();
  }

  #persist(): void {
    const tmp = `${this.#path}.${process.pid}.tmp`;
    mkdirSync(dirname(this.#path), { recursive: true });
    writeFileSync(tmp, JSON.stringify(this.#file, null, 2), { mode: 0o600 });
    renameSync(tmp, this.#path);
  }
}

/**
 * A store that cannot be read is treated as empty rather than fatal: losing
 * the resume pointer degrades chat to a fresh session, which is recoverable,
 * whereas refusing to start is not. A malformed file is reported on stderr.
 */
function readStore(path: string): StoreFile {
  let text: string;
  try {
    text = readFileSync(path, 'utf8');
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT') {
      process.stderr.write(`nvime: cannot read session store ${path}: ${String(cause)}\n`);
    }
    return { version: 1, projects: {} };
  }
  try {
    const parsed = JSON.parse(text) as StoreFile;
    if (parsed.version !== 1 || typeof parsed.projects !== 'object' || parsed.projects === null) {
      throw new Error('unexpected shape');
    }
    return parsed;
  } catch (cause) {
    process.stderr.write(`nvime: ignoring corrupt session store ${path}: ${String(cause)}\n`);
    return { version: 1, projects: {} };
  }
}
