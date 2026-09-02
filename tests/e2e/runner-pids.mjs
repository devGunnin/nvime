// Pids of LIVE detached big-change runners recorded under one scenario's
// scratch directory, one per line. Exit 1, loudly, if any record could not be
// read — the caller decides what a half-blind reaper means, and it must never
// look like "no runners".
//
// A build runner is spawned `detached: true`, so Node calls setsid(): it leads
// its own session, is reparented to init, and is NOT in the scenario's process
// group. Killing the group cannot reach it. The store is the only place its pid
// is written down.
//
// LIVENESS IS THE POINT. `session.runner` is deliberately left behind when a
// runner exits — that is how "the build died" is told apart from "the build is
// running" — so after every completed build the store still names a dead pid.
// Signalling that number kills whatever recycled it.
//
// The predicate is mirrored from agent/src/bigstore.ts (`LOCK_STALE_MS`,
// `isLockLive`, `isPidAlive`, `liveRunnerFor`); that file is TypeScript and the
// shipped bundle does not export it, so it cannot be imported here.
// `tests/e2e/selftest.sh` fails if the threshold below drifts from it.
//
// Two deliberate differences, both narrowing what may be signalled:
//   - a lock from ANOTHER host is never live here. The product returns true
//     (it cannot check a remote pid); a killer must not, or it signals whatever
//     local process happens to hold that number.
//   - a live claim with no `session.runner` yet still counts, so a runner
//     inside its handshake window is reapable. It is the CLAIM that vouches for
//     the pid; the recorded runner only has to agree with it.
//
// Usage: node runner-pids.mjs <scratch-dir>
import { readdirSync, readFileSync } from 'node:fs';
import { hostname } from 'node:os';
import { join } from 'node:path';

/** agent/src/bigstore.ts:189. Keep in step; the selftest checks that. */
const LOCK_STALE_MS = 15_000;
const MAX_DEPTH = 10;

const root = process.argv[2];
if (root === undefined || root === '') {
  process.stderr.write('usage: runner-pids.mjs <scratch-dir>\n');
  process.exit(2);
}

/** Records that could not be read. Any entry means the answer is incomplete. */
const problems = [];

/** Parsed JSON, null when the file is not there, undefined when it is unreadable. */
function readRecord(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (cause) {
    // Gone is normal: this runs while a scenario is being torn down.
    if (cause.code === 'ENOENT') return null;
    problems.push(`${path}: ${cause.code ?? cause.message}`);
    return undefined;
  }
  try {
    return JSON.parse(text);
  } catch (cause) {
    problems.push(`${path}: not JSON (${cause.message})`);
    return undefined;
  }
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (cause) {
    // EPERM means it exists and belongs to someone else; ESRCH means it is gone.
    return cause.code === 'EPERM';
  }
}

/** A claim with someone provably behind it, on this host, right now. */
function claimIsLive(lock) {
  if (lock === null || lock === undefined || typeof lock !== 'object') return false;
  if (lock.host !== hostname()) return false;
  if (!Number.isInteger(lock.heartbeatAt) || Date.now() - lock.heartbeatAt > LOCK_STALE_MS) return false;
  return pidAlive(lock.pid);
}

/** The pid this session directory vouches for, or null. */
function livePidIn(dir) {
  const lock = readRecord(join(dir, 'lock.json'));
  if (!claimIsLive(lock)) return null;
  const session = readRecord(join(dir, 'session.json'));
  const recorded = session === null || session === undefined ? null : session.runner;
  // A record that names a DIFFERENT pid than the claim describes two runs, and
  // neither can be vouched for.
  if (recorded != null && recorded.pid !== lock.pid) return null;
  return lock.pid;
}

const pids = new Set();

function walk(dir, depth) {
  if (depth > MAX_DEPTH) return;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch (cause) {
    if (cause.code !== 'ENOENT') problems.push(`${dir}: ${cause.code ?? cause.message}`);
    return;
  }
  let holdsRecord = false;
  for (const entry of entries) {
    if (entry.isDirectory()) {
      walk(join(dir, entry.name), depth + 1);
    } else if (entry.name === 'lock.json') {
      holdsRecord = true;
    }
  }
  if (!holdsRecord) return;
  const pid = livePidIn(dir);
  if (pid !== null) pids.add(pid);
}

walk(root, 0);
for (const pid of [...pids].sort((a, b) => a - b)) process.stdout.write(`${pid}\n`);
if (problems.length > 0) {
  for (const problem of problems) process.stderr.write(`runner-pids: could not read ${problem}\n`);
  process.exit(1);
}
