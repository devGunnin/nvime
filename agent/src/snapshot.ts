import { readFileSync, statSync } from 'node:fs';

/**
 * What a file looked like at one instant. Edit mode takes one before the tool
 * runs and one after it finishes, and the pair IS the recorded mutation — the
 * plugin applies it to the buffer and the changeset reverts it.
 *
 * Not every file can be carried as text, so `opaque` is a first-class outcome
 * rather than an empty string: the plugin reloads such a file from disk
 * instead of pretending it knows the contents.
 */
export type Snapshot =
  | { kind: 'text'; text: string }
  | { kind: 'absent' }
  | { kind: 'opaque'; reason: 'binary' | 'oversize' | 'unreadable'; bytes: number };

/** Above this a file is recorded as `oversize`; source files are far below it. */
export const MAX_SNAPSHOT_BYTES = 1024 * 1024;

export function readSnapshot(path: string, maxBytes: number = MAX_SNAPSHOT_BYTES): Snapshot {
  let bytes: number;
  try {
    const stat = statSync(path);
    if (!stat.isFile()) return { kind: 'opaque', reason: 'unreadable', bytes: 0 };
    bytes = stat.size;
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return { kind: 'absent' };
    return { kind: 'opaque', reason: 'unreadable', bytes: 0 };
  }
  if (bytes > maxBytes) return { kind: 'opaque', reason: 'oversize', bytes };
  let buffer: Buffer;
  try {
    buffer = readFileSync(path);
  } catch {
    return { kind: 'opaque', reason: 'unreadable', bytes };
  }
  // A NUL byte is the cheap, conventional binary test; UTF-8 text has none.
  if (buffer.includes(0)) return { kind: 'opaque', reason: 'binary', bytes: buffer.length };
  const text = buffer.toString('utf8');
  // Invalid UTF-8 decodes to replacement characters, so `text` would no longer
  // describe the file's bytes: the editor would write the mangled version back
  // and the plugin's disk check would see a change nobody made.
  if (!Buffer.from(text, 'utf8').equals(buffer)) {
    return { kind: 'opaque', reason: 'binary', bytes: buffer.length };
  }
  return { kind: 'text', text };
}

/**
 * Whether two snapshots are known to describe the same file. Two opaque
 * snapshots are never equal: nothing was read, so "unchanged" cannot be
 * claimed, and reporting a change the user can see beats hiding one.
 */
export function sameSnapshot(a: Snapshot, b: Snapshot): boolean {
  if (a.kind === 'absent' && b.kind === 'absent') return true;
  if (a.kind === 'text' && b.kind === 'text') return a.text === b.text;
  return false;
}

/** Retained size of a snapshot, for the change log's memory budget. */
export function snapshotBytes(snapshot: Snapshot): number {
  return snapshot.kind === 'text' ? Buffer.byteLength(snapshot.text, 'utf8') : 0;
}
