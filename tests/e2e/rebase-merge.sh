#!/usr/bin/env bash
# Issue #10 end to end, against the real claude CLI and the real detached runner:
#
#   1. build a --version flag in a scratch repo
#   2. move main under it with an unrelated commit
#   3. M in the review tab refuses with base-moved
#   4. R rebases the build onto the new main, spinner and all
#   5. M merges
#
# Not part of the unit suites: it costs tokens and needs a login.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"
work="${NVIME_E2E_WORK:-$(mktemp -d)}"
export NVIME_E2E_MODEL="${NVIME_E2E_MODEL:-sonnet}"

repo="$work/repo"
# All four homes, so nothing this scenario writes — the session store, the
# debug log, the bundle — can land in the developer's own.
export XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state"
export XDG_CACHE_HOME="$work/cache"
export NVIME_E2E_REPO="$repo"
export NVIME_E2E_OUT="$work/report.txt"
export NVIME_E2E_MOVE="NOTES.md"
: >"$NVIME_E2E_OUT"

mkdir -p "$repo" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
cat >"$repo/greet.py" <<'PY'
import sys


def main(argv):
    print("hello")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
git -C "$repo" init -q -b main
git -C "$repo" config user.email e2e@nvime
git -C "$repo" config user.name e2e
git -C "$repo" add -A
git -C "$repo" commit -qm 'greet'

npm --prefix "$plugin/agent" run build >/dev/null

printf '== build, move the base, refuse, rebase, merge\n'
nvim --clean --headless -l "$here/rebase-merge.lua"

cat "$NVIME_E2E_OUT"
for marker in BUILT MOVED REFUSED REBASED MERGED; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done
grep -q '^NOTICE .*has moved since the build started' "$NVIME_E2E_OUT" ||
  { echo 'the reader was never told the base had moved'; exit 1; }
grep -q '^NOTICE .*press R to rebase' "$NVIME_E2E_OUT" ||
  { echo 'the refusal did not offer the rebase'; exit 1; }
# The fix this smoke exists for: a rebase is minutes long, and the tab shows it.
grep -q '^ACTIVITY R .*spinner=true' "$NVIME_E2E_OUT" ||
  { echo 'the rebase ran with no visible indicator'; exit 1; }

# The proof is in the operator's repository, not in what the sidecar said: the
# reviewed change is on main, and main is where the merge said it left it.
merged="$(awk '/^MERGED /{print $2}' "$NVIME_E2E_OUT")"
head="$(git -C "$repo" rev-parse main)"
[ "$merged" = "$head" ] || { echo "main is at $head, not the merged $merged"; exit 1; }
git -C "$repo" show --stat main | grep -q greet.py || { echo 'the landed commit did not touch greet.py'; exit 1; }
grep -q 'moved on while the build was running' "$repo/$NVIME_E2E_MOVE" ||
  { echo 'the merge lost the commit that moved the base'; exit 1; }

printf 'PASS — base moved, R rebased onto it, M landed on main (%s)\n' "$work"
