import { lstatSync, readlinkSync, realpathSync } from 'node:fs';
import { dirname, isAbsolute, join, parse, sep } from 'node:path';

/**
 * What edit mode lets the agent do, decided in the sidecar and enforced
 * through the SDK's `canUseTool` callback — never through prompt text, which
 * the model is free to ignore.
 *
 * Writes under the project root are the whole point, so they run unattended.
 * Everything that can reach outside the project — a write to another path, a
 * shell command — stops here and asks the editor. An unrecognized tool asks
 * too: the fail-safe direction is the one that needs a human.
 */

export const READ_ONLY_TOOLS = ['Read', 'Glob', 'Grep', 'WebFetch', 'WebSearch'] as const;

/** Tools that change a file. Each names its target through one input key. */
export const FILE_PATH_KEYS: Readonly<Record<string, string>> = {
  Edit: 'file_path',
  Write: 'file_path',
  NotebookEdit: 'notebook_path',
};

export const SHELL_TOOLS = ['Bash', 'BashOutput', 'KillShell'] as const;

export type ToolDecision =
  | { kind: 'allow'; path?: string }
  | { kind: 'ask'; reason: string; path?: string }
  | { kind: 'deny'; reason: string };

/**
 * Ceiling on symlinks followed while resolving one path, the way the kernel
 * bounds it. `realpathSync` raises ELOOP for a cycle whose links all resolve;
 * this bounds the dangling ones it never gets to see.
 */
const MAX_SYMLINK_HOPS = 40;

/** Remaining symlink hops for one whole resolution, shared down the walk. */
interface Hops {
  left: number;
}

/**
 * The symlink semantics, stated once because getting them wrong is a write
 * outside the project with no approval:
 *
 * `realpathSync` raises `ENOENT` for two very different components, and they
 * must not be conflated.
 *   * A component that is genuinely absent — the normal case for a `Write`
 *     creating a file — resolves to itself, so the write is judged where it
 *     will land.
 *   * A component that IS a symlink whose target does not exist resolves
 *     THROUGH its link text, because that is what the kernel does with it:
 *     `<root>/deploy -> ~/.bashrc.d/x.sh` puts the bytes in the home
 *     directory. Treating it as "absent" classified it as an in-root write.
 * Any other error (permission, symlink loop) is a real failure and propagates.
 */
function resolveComponent(path: string, hops: Hops): string {
  try {
    return realpathSync(path);
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
    const linkText = danglingLinkText(path);
    if (linkText === null) return path;
    return followLink(path, linkText, hops);
  }
}

/** The link text of `path` when it is a symlink, or null when it is not one. */
function danglingLinkText(path: string): string | null {
  try {
    if (!lstatSync(path).isSymbolicLink()) return null;
    return readlinkSync(path);
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code === 'ENOENT' || code === 'ENOTDIR') return null;
    throw cause;
  }
}

/** Where a dangling symlink actually points, resolved from its own directory. */
function followLink(linkPath: string, linkText: string, hops: Hops): string {
  hops.left -= 1;
  if (hops.left < 0) {
    const loop = new Error(
      `ELOOP: too many symbolic links encountered, resolving '${linkPath}'`,
    ) as NodeJS.ErrnoException;
    loop.code = 'ELOOP';
    throw loop;
  }
  // `dirname(linkPath)` is already resolved — the walk got here through it.
  const target = isAbsolute(linkText) ? linkText : dirname(linkPath) + sep + linkText;
  return walk(target, hops);
}

/**
 * `target` resolved the way the kernel resolves it: one component at a time,
 * left to right, each symlink followed before the next segment is applied.
 *
 * `path.resolve` must NOT be used for this. It collapses `..` lexically, on
 * the string, before any symlink is followed — so `<root>/link-to-outside/..`
 * comes back as `<root>`, while the kernel walks out of the link's target and
 * the write lands outside the project. Resolving per component closes that.
 */
function walk(target: string, hops: Hops): string {
  // Concatenated, not `join`ed: both `join` and `resolve` would collapse `..`
  // on the way in, which is the whole bug.
  const anchored = isAbsolute(target) ? target : process.cwd() + sep + target;
  const base = parse(anchored).root;
  let resolved = resolveComponent(base, hops);
  for (const segment of anchored.slice(base.length).split(sep)) {
    if (segment === '' || segment === '.') continue;
    // Applied to the RESOLVED prefix, so `..` after a symlink climbs out of
    // the link's target, not out of the written path's lexical parent.
    resolved = segment === '..' ? dirname(resolved) : resolveComponent(join(resolved, segment), hops);
  }
  return resolved;
}

/** @see walk — the real destination of `target`, symlinks and all. */
export function realPathOf(target: string): string {
  if (typeof target !== 'string' || target === '') {
    throw new TypeError('realPathOf needs a non-empty path');
  }
  return walk(target, { left: MAX_SYMLINK_HOPS });
}

export type PathResolution = { ok: true; path: string } | { ok: false; reason: string };

/**
 * `realPathOf` as a value rather than a throw. A path the kernel itself cannot
 * resolve — a symlink loop, a directory the user may not traverse — is one
 * tool call to refuse, not a reason to lose the whole run to a raw errno.
 */
export function tryRealPathOf(target: string): PathResolution {
  try {
    return { ok: true, path: realPathOf(target) };
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    return { ok: false, reason: `nvime could not resolve that path: ${message}` };
  }
}

/** True when `candidate` is `root` itself or sits under it. Both must be real paths. */
export function isWithin(root: string, candidate: string): boolean {
  if (candidate === root) return true;
  const prefix = root.endsWith(sep) ? root : root + sep;
  return candidate.startsWith(prefix);
}

function readPath(input: Record<string, unknown>, key: string): string | null {
  const value = input[key];
  return typeof value === 'string' && value !== '' ? value : null;
}

/**
 * The policy itself. `realRoot` must already be symlink-resolved; passing a
 * raw root would let a symlinked project directory fail every containment
 * check and turn edit mode into one long approval prompt.
 */
export function classifyTool(
  toolName: string,
  input: Record<string, unknown>,
  realRoot: string,
): ToolDecision {
  if ((READ_ONLY_TOOLS as readonly string[]).includes(toolName)) return { kind: 'allow' };
  if ((SHELL_TOOLS as readonly string[]).includes(toolName)) {
    return { kind: 'ask', reason: 'runs a shell command' };
  }
  const key = FILE_PATH_KEYS[toolName];
  if (key === undefined) {
    return { kind: 'ask', reason: `nvime has no policy for the ${toolName} tool` };
  }
  const raw = readPath(input, key);
  if (raw === null) return { kind: 'deny', reason: `${toolName} named no ${key}` };
  if (!isAbsolute(raw)) return { kind: 'deny', reason: `${toolName} needs an absolute ${key}` };
  const resolved = tryRealPathOf(raw);
  if (!resolved.ok) return { kind: 'deny', reason: resolved.reason };
  if (isWithin(realRoot, resolved.path)) return { kind: 'allow', path: resolved.path };
  return { kind: 'ask', reason: 'writes outside the project root', path: resolved.path };
}
