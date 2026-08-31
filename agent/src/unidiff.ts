import { createHash } from 'node:crypto';

/**
 * A unified diff, as `git diff <base>` writes it, split into files and hunks.
 * Pure: the parser never touches git or the filesystem, so every rule below is
 * testable on a string.
 *
 * Hunk boundaries are found by counting the lines each `@@` header promises
 * rather than by scanning for the next `@@`/`---`. Diff CONTENT can contain
 * either — a patch inside a test fixture is the ordinary case — and a scanner
 * that trusts the prefix splits the file in the middle of a hunk.
 */

export type FileStatus = 'added' | 'deleted' | 'modified' | 'renamed';

export interface DiffHunk {
  /** Unique within one capture; the model refers to hunks by this. */
  id: string;
  /** Path on the "b" side, or the "a" side for a deletion. */
  file: string;
  header: string;
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  /** Body lines, each keeping its ` `/`+`/`-` prefix. */
  lines: string[];
  /**
   * 0-based index of this hunk's `@@` line in the diff text, and how many
   * lines it spans from there. The editor slices the raw diff with these
   * instead of being sent every hunk body a second time. -1/0 when synthetic.
   */
  offset: number;
  lineCount: number;
  /**
   * True for a hunk nvime synthesized because git described the change
   * without one (a binary file, a pure rename, a mode change). It stands in
   * the thread list so no change is invisible, but it is not a patch.
   */
  synthetic: boolean;
  /** Content hash; the key revisions carry resolved state forward with. */
  signature: string;
}

export interface DiffFile {
  path: string;
  oldPath: string;
  status: FileStatus;
  binary: boolean;
  hunks: DiffHunk[];
}

export interface ParsedDiff {
  files: DiffFile[];
  hunks: DiffHunk[];
}

/** Ceiling on a captured diff. Past it the capture is refused, not silently cut. */
export const MAX_DIFF_BYTES = 8 * 1024 * 1024;

interface FileDraft {
  path: string;
  oldPath: string;
  status: FileStatus;
  binary: boolean;
  hunks: DiffHunk[];
}

export function parseUnifiedDiff(text: string): ParsedDiff {
  if (typeof text !== 'string') throw new TypeError('parseUnifiedDiff needs a string');
  const lines = text.split('\n');
  const files: FileDraft[] = [];
  let current: FileDraft | null = null;
  let at = 0;

  while (at < lines.length) {
    const line = lines[at] ?? '';
    if (line.startsWith('diff --git ')) {
      current = startFile(line);
      files.push(current);
      at += 1;
      continue;
    }
    if (current === null) {
      at += 1;
      continue;
    }
    if (line.startsWith('@@')) {
      at = readHunk(lines, at, current, files.length);
      continue;
    }
    applyHeaderLine(line, current);
    at += 1;
  }

  files.forEach((file, index) => fillEmptyFile(file, index + 1));
  const hunks = files.flatMap((file) => file.hunks);
  return { files, hunks };
}

/** The `diff --git a/x b/x` line: both paths, before any header refines them. */
function startFile(line: string): FileDraft {
  const rest = line.slice('diff --git '.length);
  const [a, b] = splitPathPair(rest);
  return { path: strip(b), oldPath: strip(a), status: 'modified', binary: false, hunks: [] };
}

/**
 * Splits `a/x b/x` into its two paths. Either side may be C-quoted, and an
 * unquoted path may contain spaces — so the unquoted case is split at the
 * midpoint, which is where git puts the boundary when both sides are the
 * same length, and refined later by the `---`/`+++` header lines.
 */
function splitPathPair(rest: string): [string, string] {
  if (rest.startsWith('"')) {
    const end = closingQuote(rest);
    if (end > 0) return [unquote(rest.slice(0, end + 1)), unquote(rest.slice(end + 2))];
  }
  const half = (rest.length - 1) / 2;
  if (Number.isInteger(half) && rest[half] === ' ') {
    return [rest.slice(0, half), unquote(rest.slice(half + 1))];
  }
  const space = rest.indexOf(' ');
  return space === -1 ? [rest, rest] : [rest.slice(0, space), unquote(rest.slice(space + 1))];
}

/** Index of the quote closing the one at position 0, or -1. */
function closingQuote(text: string): number {
  for (let i = 1; i < text.length; i += 1) {
    if (text[i] === '\\') {
      i += 1;
      continue;
    }
    if (text[i] === '"') return i;
  }
  return -1;
}

/** Drops the `a/` or `b/` prefix git puts on every path in a diff header. */
function strip(path: string): string {
  if (path === '/dev/null') return path;
  return path.startsWith('a/') || path.startsWith('b/') ? path.slice(2) : path;
}

/**
 * git C-quotes a path with spaces, quotes or non-ASCII bytes. Only the escapes
 * git actually emits are decoded; anything else is left as written rather than
 * guessed at.
 */
function unquote(path: string): string {
  if (!path.startsWith('"') || !path.endsWith('"') || path.length < 2) return path;
  const body = path.slice(1, -1);
  const bytes: number[] = [];
  for (let i = 0; i < body.length; i += 1) {
    if (body[i] !== '\\') {
      bytes.push(...Buffer.from(body[i] ?? '', 'utf8'));
      continue;
    }
    const next = body[i + 1] ?? '';
    const octal = body.slice(i + 1, i + 4);
    if (/^[0-7]{3}$/.test(octal)) {
      bytes.push(Number.parseInt(octal, 8));
      i += 3;
      continue;
    }
    const simple: Record<string, number> = { n: 10, t: 9, r: 13, '"': 34, '\\': 92 };
    const code = simple[next];
    bytes.push(code ?? Buffer.from(next, 'utf8')[0] ?? 0);
    i += 1;
  }
  return Buffer.from(bytes).toString('utf8');
}

/** One `diff --git` header line that is not a hunk. */
function applyHeaderLine(line: string, file: FileDraft): void {
  if (line.startsWith('new file mode')) file.status = 'added';
  else if (line.startsWith('deleted file mode')) file.status = 'deleted';
  else if (line.startsWith('rename from ')) file.oldPath = unquote(line.slice('rename from '.length));
  else if (line.startsWith('rename to ')) {
    file.status = 'renamed';
    file.path = unquote(line.slice('rename to '.length));
  } else if (line.startsWith('Binary files ') || line.startsWith('GIT binary patch')) file.binary = true;
  else if (line.startsWith('--- ')) {
    const path = strip(unquote(line.slice(4)));
    if (path !== '/dev/null') file.oldPath = path;
  } else if (line.startsWith('+++ ')) {
    const path = strip(unquote(line.slice(4)));
    if (path !== '/dev/null') file.path = path;
    else file.path = file.oldPath;
  }
}

const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

/**
 * Consumes one hunk starting at `start`, and returns the index just past it.
 * The two line counters are the authority on where the hunk ends; content that
 * looks like a header stops nothing while either still has lines owed.
 */
function readHunk(lines: string[], start: number, file: FileDraft, fileNumber: number): number {
  const header = lines[start] ?? '';
  const match = HUNK_HEADER.exec(header);
  if (match === null) return start + 1;
  const oldCount = match[2] === undefined ? 1 : Number(match[2]);
  const newCount = match[4] === undefined ? 1 : Number(match[4]);
  let oldLeft = oldCount;
  let newLeft = newCount;
  const body: string[] = [];
  let at = start + 1;
  while (at < lines.length && (oldLeft > 0 || newLeft > 0)) {
    const line = lines[at] ?? '';
    const kind = line[0];
    if (kind === '\\') {
      // "\ No newline at end of file" belongs to neither side's count.
      body.push(line);
      at += 1;
      continue;
    }
    if (kind === '-') oldLeft -= 1;
    else if (kind === '+') newLeft -= 1;
    else if (kind === ' ' || line === '') {
      // git writes a context line for an empty source line as a bare "".
      oldLeft -= 1;
      newLeft -= 1;
    } else break;
    body.push(line);
    at += 1;
  }
  file.hunks.push(
    makeHunk({
      id: `h${fileNumber}.${file.hunks.length + 1}`,
      file: file.path,
      header,
      oldStart: Number(match[1]),
      oldCount,
      newStart: Number(match[3]),
      newCount,
      lines: body,
      offset: start,
      lineCount: at - start,
      synthetic: false,
    }),
  );
  return at;
}

/**
 * A change git described with no hunk — binary content, a pure rename, a mode
 * change — still gets one, so it appears in the thread list. Dropping it would
 * mean a file changed that the reviewer is never shown.
 */
function fillEmptyFile(file: FileDraft, fileNumber: number): void {
  if (file.hunks.length > 0) return;
  const what = file.binary ? 'binary content changed' : `${file.status}, no textual change`;
  file.hunks.push(
    makeHunk({
      id: `h${fileNumber}.1`,
      file: file.path,
      header: `@@ ${file.path} @@`,
      oldStart: 0,
      oldCount: 0,
      newStart: 0,
      newCount: 0,
      lines: [what],
      offset: -1,
      lineCount: 0,
      synthetic: true,
    }),
  );
}

function makeHunk(hunk: Omit<DiffHunk, 'signature'>): DiffHunk {
  return { ...hunk, signature: signatureOf(hunk.file, hunk.lines) };
}

/**
 * Identity of a hunk's content, independent of where it sits in the diff. A
 * revision that leaves a hunk untouched produces the same signature, which is
 * how resolved and auto-resolved state survives a re-triage.
 */
export function signatureOf(file: string, lines: readonly string[]): string {
  return createHash('sha256').update(file).update('\n').update(lines.join('\n')).digest('hex').slice(0, 16);
}

/** The hunk bodies, labelled with their ids — what the triage turn reads. */
export function renderForTriage(parsed: ParsedDiff, maxBytes: number): { text: string; truncated: boolean } {
  const parts: string[] = [];
  let bytes = 0;
  let truncated = false;
  for (const file of parsed.files) {
    for (const hunk of file.hunks) {
      const block = `[${hunk.id}] ${file.status} ${hunk.file}\n${hunk.header}\n${hunk.lines.join('\n')}\n`;
      bytes += Buffer.byteLength(block, 'utf8');
      if (bytes > maxBytes) {
        truncated = true;
        break;
      }
      parts.push(block);
    }
    if (truncated) break;
  }
  return { text: parts.join('\n'), truncated };
}
