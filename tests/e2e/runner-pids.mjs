// Pids of detached big-change runners recorded under one scenario's scratch
// directory, one per line.
//
// A build runner is spawned `detached: true`, so Node calls setsid(): it leads
// its own session, is reparented to init, and is NOT in the scenario's process
// group. Killing the group cannot reach it. The store is the only place its pid
// is written down — `session.json`'s `runner.pid` once the handshake is done,
// and `lock.json`'s `pid` from the moment it claims the run.
//
// Usage: node runner-pids.mjs <scratch-dir>
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const MAX_DEPTH = 10;
const PID_FILES = new Set(['session.json', 'lock.json']);

const root = process.argv[2];
if (root === undefined || root === '') {
  process.stderr.write('usage: runner-pids.mjs <scratch-dir>\n');
  process.exit(2);
}

const pids = new Set();

/** `record.runner.pid` or `record.pid`, when it is a plausible process id. */
function collect(record) {
  for (const pid of [record?.runner?.pid, record?.pid]) {
    if (Number.isInteger(pid) && pid > 1) pids.add(pid);
  }
}

function walk(dir, depth) {
  if (depth > MAX_DEPTH) return;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    // A directory that is unreadable or already gone is normal here: this runs
    // while the scenario is being torn down. Nothing else can be said about it.
    return;
  }
  for (const entry of entries) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(path, depth + 1);
    } else if (PID_FILES.has(entry.name)) {
      try {
        collect(JSON.parse(readFileSync(path, 'utf8')));
      } catch {
        // Half-written or not JSON. A record we cannot read names no pid.
      }
    }
  }
}

walk(root, 0);
for (const pid of [...pids].sort((a, b) => a - b)) process.stdout.write(`${pid}\n`);
