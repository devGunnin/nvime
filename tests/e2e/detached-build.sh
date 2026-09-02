#!/usr/bin/env bash
# The proof that a big-change build outlives its editor and can be steered:
#
#   1. headless Neovim A specs and starts a build, then exits entirely
#   2. the build log keeps growing with A gone
#   3. headless Neovim B attaches, steers it mid-build, and follows it to the end
#   4. the final reviewed diff carries what B asked for
#
# Real claude CLI, real detached runner, tiny scope. Not part of the unit
# suites: it costs tokens and needs a login.
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
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=e2e@nvime -c user.name=e2e add -A
git -C "$repo" -c user.email=e2e@nvime -c user.name=e2e commit -qm 'greet'

npm --prefix "$plugin/agent" run build >/dev/null

say() { printf '== %s\n' "$1"; }

say 'editor A: spec, approve, start the build, then exit'
nvim --clean --headless -l "$here/start-build.lua"
grep -q '^RUNNING ' "$NVIME_E2E_OUT" || { cat "$NVIME_E2E_OUT"; exit 1; }
session="$(awk '/^SESSION /{print $2}' "$NVIME_E2E_OUT")"
log="$(awk '/^RUNNING /{print $2}' "$NVIME_E2E_OUT")"
before="$(wc -l <"$log")"

say "editor A is gone; watching $log grow from $before lines"
grew=0
for _ in $(seq 1 60); do
  sleep 1
  now="$(wc -l <"$log")"
  if [ "$now" -gt "$before" ]; then grew=1; break; fi
done
[ "$grew" = 1 ] || { echo "the build stopped when its editor did"; exit 1; }
say "the build kept going with no editor attached ($(wc -l <"$log") lines)"

say 'editor B: attach, steer, follow to the end'
NVIME_E2E_SESSION="$session" nvim --clean --headless -l "$here/steer-build.lua"

cat "$NVIME_E2E_OUT"
for marker in ATTACHED STEERED HAS_VERSION HAS_STEERED_HELP; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done
grep -qE '^FINAL (reviewing|mergeable) threads=[1-9]' "$NVIME_E2E_OUT" || {
  echo 'the runner did not finish with triaged threads'
  exit 1
}
say "PASS — the build outlived its editor, took a steer, and triaged itself ($work)"
