import { createInterface } from 'node:readline';
import { BigStore, type BigSession } from '../../src/bigstore.js';

/**
 * One contender in the M1 stale-takeover race, kept alive across every trial
 * instead of respawned per trial: node+tsx startup jitter (hundreds of ms) is
 * far larger than the race window this reproduces (microseconds), so two
 * fresh processes almost never land inside `acquireLock` at the same instant.
 * A persistent worker removes that jitter from the loop — the parent writes
 * one session id per line and this races the OTHER persistent contender's
 * `acquireLock` on it, replying with one JSON result line per trial.
 *
 * usage: lock-contender.ts <storeRoot> <repoRoot>
 */

const [, , storeRoot, repoRoot] = process.argv;
if (storeRoot === undefined || repoRoot === undefined) {
  process.stderr.write('usage: lock-contender <storeRoot> <repoRoot>\n');
  process.exit(2);
}

const store = new BigStore(storeRoot);

/** True when, right now, this store handle's own live claim is the one on disk. */
function stillMine(session: BigSession): boolean {
  const raw = store.readLock(session);
  return raw !== null && store.foreignLock(session) === null;
}

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const sessionId = line.trim();
  if (sessionId === '') return;
  const session = { repoRoot, id: sessionId } as BigSession;

  let lock;
  try {
    lock = store.acquireLock(session, 'contender');
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    process.stdout.write(`${JSON.stringify({ result: 'busy', message })}\n`);
    return;
  }
  // The instant after a successful claim: the M1 bug deleted the winner's
  // fresh claim on the way out of the loser's stale-lock cleanup.
  const stolenImmediately = !stillMine(session);
  process.stdout.write(`${JSON.stringify({ result: 'acquired', stolenImmediately })}\n`);
  lock.release();
});
