#!/usr/bin/env bash
# A fresh install, end to end against the real claude CLI:
#
#   1. empty XDG homes — no config, no session store, no debug log
#   2. `:Nvime` opens the dashboard on a machine that has never run it
#   3. the sidecar starts on first use and answers with the local claude
#   4. one trivial big change builds to a reviewable diff
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

mkdir -p "$repo" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
: >"$NVIME_E2E_OUT"

# The premise of the scenario, checked rather than assumed: every home is bare.
for home in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"; do
  if [ -n "$(ls -A "$home")" ]; then
    echo "not a cold start: $home already has something in it"
    exit 1
  fi
done

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

printf '== cold start: dashboard, sidecar, one small build\n'
nvim --clean --headless -l "$here/cold-start.lua"

cat "$NVIME_E2E_OUT"
for marker in PING DASHBOARD BUILT DIFF SESSION BIGSTORE; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done

# Where the change actually landed — a cold start that wrote into the
# developer's real data directory is the bug this guards.
store="$(awk '/^BIGSTORE /{print $2}' "$NVIME_E2E_OUT")"
session="$(awk '/^SESSION /{print $2}' "$NVIME_E2E_OUT")"
case "$store" in
  "$XDG_DATA_HOME"/*) ;;
  *) echo "the build stored its session outside the scratch home: $store"; exit 1 ;;
esac
[ -n "$(find "$store" -maxdepth 2 -name "$session" 2>/dev/null)" ] ||
  { echo "the cold start left no session record under $store"; exit 1; }

printf 'PASS — nvime came up on an empty machine and built a change (%s)\n' "$work"
