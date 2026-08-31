import { realpathSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve, sep } from 'node:path';

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
 * `target` with every symlink on its existing prefix resolved. `realpathSync`
 * fails outright on a path that does not exist yet, which is the normal case
 * for a `Write` creating a file — so the deepest existing ancestor is resolved
 * and the remaining segments are rejoined. Without this a symlink inside the
 * project pointing at `/etc` would look like a path under the root.
 */
export function realPathOf(target: string): string {
  let head = resolve(target);
  const tail: string[] = [];
  for (;;) {
    try {
      return tail.length === 0 ? realpathSync(head) : join(realpathSync(head), ...tail);
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code;
      if (code !== 'ENOENT' && code !== 'ENOTDIR') throw cause;
      const parent = dirname(head);
      // Reached the filesystem root without finding anything that exists.
      if (parent === head) return tail.length === 0 ? head : join(head, ...tail);
      tail.unshift(basename(head));
      head = parent;
    }
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
  const path = realPathOf(raw);
  if (isWithin(realRoot, path)) return { kind: 'allow', path };
  return { kind: 'ask', reason: 'writes outside the project root', path };
}
