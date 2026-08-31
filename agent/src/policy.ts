import { realpathSync } from 'node:fs';
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
 * `realpathSync` on one existing component, or the component itself when it
 * does not exist yet — the normal case for a `Write` creating a file. Any
 * other error (a permission or symlink-loop failure) is a real failure and is
 * left to propagate rather than resolving to a path the kernel would refuse.
 */
function resolveComponent(path: string): string {
  try {
    return realpathSync(path);
  } catch (cause) {
    const code = (cause as NodeJS.ErrnoException).code;
    if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
    return path;
  }
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
export function realPathOf(target: string): string {
  if (typeof target !== 'string' || target === '') {
    throw new TypeError('realPathOf needs a non-empty path');
  }
  // Concatenated, not `join`ed: both `join` and `resolve` would collapse `..`
  // on the way in, which is the whole bug.
  const anchored = isAbsolute(target) ? target : process.cwd() + sep + target;
  const base = parse(anchored).root;
  let resolved = resolveComponent(base);
  for (const segment of anchored.slice(base.length).split(sep)) {
    if (segment === '' || segment === '.') continue;
    // Applied to the RESOLVED prefix, so `..` after a symlink climbs out of
    // the link's target, not out of the written path's lexical parent.
    resolved = segment === '..' ? dirname(resolved) : resolveComponent(join(resolved, segment));
  }
  return resolved;
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
  const path = realPathOf(raw);
  if (isWithin(realRoot, path)) return { kind: 'allow', path };
  return { kind: 'ask', reason: 'writes outside the project root', path };
}
