#!/usr/bin/env bash
# The diagnostics path, proven against a real build:
#
#   1. turn the debug log on, then build a change whose TITLE is a sentinel —
#      so the sentinel reaches the branch name, the spec and the state lines
#   2. `:Nvime log` renders the run
#   3. `:Nvime bundle` writes an attachable file
#   4. the sentinel appears in NEITHER the log NOR the bundle (the log is deny
#      by default), while the change's id and base sha appear in the bundle
#
# Not part of the unit suites: it costs tokens and needs a login.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"
work="${NVIME_E2E_WORK:-$(mktemp -d)}"
export NVIME_E2E_MODEL="${NVIME_E2E_MODEL:-sonnet}"

repo="$work/repo"
export XDG_CONFIG_HOME="$work/config"
export XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state"
export XDG_CACHE_HOME="$work/cache"
export NVIME_E2E_REPO="$repo"
export NVIME_E2E_OUT="$work/report.txt"

# Lower-case and alphanumeric on purpose: a title becomes a branch through a
# slug, and a sentinel that survives slugging is one string to grep for.
sentinel_tag="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
export NVIME_E2E_SENTINEL="zqsentinel$sentinel_tag"

mkdir -p "$repo" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
: >"$NVIME_E2E_OUT"

cat >"$repo/greet.py" <<'PY'
import sys


def main(argv):
    print("hello")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
# The scratch repo is the agent's to commit in, so the developer's global git
# config must not reach it: gpgsign, hooksPath or includeIf would fail a run for
# a reason that has nothing to do with nvime.
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-/dev/null}"
export GIT_CONFIG_NOSYSTEM=1

git -C "$repo" init -q -b main
git -C "$repo" config user.email e2e@nvime
git -C "$repo" config user.name e2e
git -C "$repo" add -A
git -C "$repo" commit -qm 'greet'

# The runner builds the sidecar once and says so; a wrapper run by hand builds
# for itself.
if [ "${NVIME_E2E_BUILT:-0}" != 1 ]; then
  npm --prefix "$plugin/agent" run build >/dev/null
fi

printf '== build with the log on, then :Nvime log and :Nvime bundle\n'
nvim --clean --headless -l "$here/debug-bundle.lua"

cat "$NVIME_E2E_OUT"
for marker in LOGDIR LOGPATH SESSION BUILT BASE LOGVIEW BUNDLE; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done

logdir="$(awk '/^LOGDIR /{print $2}' "$NVIME_E2E_OUT")"
bundle="$(awk '/^BUNDLE /{print $2}' "$NVIME_E2E_OUT")"
session="$(awk '/^SESSION /{print $2}' "$NVIME_E2E_OUT")"
base="$(awk '/^BASE /{print $2}' "$NVIME_E2E_OUT")"

[ -s "$bundle" ] || { echo "the bundle at $bundle is missing or empty"; exit 1; }

# The debug log must exist and have recorded the run. Every process's file and
# every rotated half of one: the leak check is only as good as its coverage.
shopt -s nullglob
logs=("$logdir"/nvime-*.log "$logdir"/nvime-*.log.1)
shopt -u nullglob
if [ "${#logs[@]}" = 0 ]; then
  echo "no debug log was written under $logdir"
  exit 1
fi
printf 'checked %s log file(s) and the bundle for the sentinel\n' "${#logs[@]}"

# The leak check, both halves. -i because the branch slug lower-cases the title.
for log in "${logs[@]}" "$bundle"; do
  if grep -il "$NVIME_E2E_SENTINEL" "$log" >/dev/null; then
    echo "the prompt leaked into $log:"
    grep -ihn "$NVIME_E2E_SENTINEL" "$log" | head -5
    exit 1
  fi
done

# What the bundle IS for: the change is identifiable from it.
grep -q "$session" "$bundle" || { echo "the bundle does not name the change ($session)"; exit 1; }
grep -q "$base" "$bundle" || { echo "the bundle does not name the base sha ($base)"; exit 1; }

printf 'PASS — the run is diagnosable and the prompt never left the editor (%s)\n' "$work"
