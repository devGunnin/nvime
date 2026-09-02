#!/usr/bin/env bash
# Issue #19 end to end: the prompt box's advertised keys, typed in insert mode
# where the box actually leaves the reader, against a real agent turn.
#
#   i_<C-s> sends · i_<C-c> stops it · i_<C-r> is history on an empty box and
#   Vim's register paste on a full one · i_<C-n>/i_<C-t> stay Vim's
#
# Cheaper than the build scenarios — it starts one real turn and cancels it —
# but still the real claude CLI: it costs tokens and needs a login.
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

printf '== type the prompt keys into the real box\n'
nvim --clean --headless -l "$here/prompt-keys.lua"

cat "$NVIME_E2E_OUT"
for marker in NATIVE SUBMITTED CANCELLED HISTORY REGISTER; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done

printf 'PASS — the prompt keys act from insert, and Vim keeps its own (%s)\n' "$work"
