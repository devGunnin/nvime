#!/usr/bin/env bash
# The review pane as real buffers, end to end against the real claude CLI:
#
#   1. build a small change in a scratch Lua repo
#   2. open the review tab on it
#   3. prove the pane is the clone's own file — normal buffer, treesitter
#      captures present, LSP-attachable, diff drawn as marks not as text
#   4. ]c walks hunks, t round-trips through the unified diff
#   5. closing the review leaves no clone buffer behind
#
# Not part of the unit suites: it costs tokens and needs a login.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"
work="${NVIME_E2E_WORK:-$(mktemp -d)}"
export NVIME_E2E_MODEL="${NVIME_E2E_MODEL:-sonnet}"

repo="$work/repo"
# Isolated: nvime writes its big-change store under XDG_DATA_HOME, and it must
# never be the operator's own.
export XDG_DATA_HOME="$work/data"
export XDG_STATE_HOME="$work/state"
export XDG_CACHE_HOME="$work/cache"
export NVIME_E2E_REPO="$repo"
export NVIME_E2E_OUT="$work/report.txt"
: >"$NVIME_E2E_OUT"

mkdir -p "$repo" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
cat >"$repo/pool.lua" <<'LUA'
local M = {}

M.cap = 30

function M.connect(attempt)
  return { attempt = attempt, delay = 1 }
end

return M
LUA
git -C "$repo" init -q -b main
git -C "$repo" config user.email e2e@nvime
git -C "$repo" config user.name e2e
git -C "$repo" add -A
git -C "$repo" commit -qm 'pool'

npm --prefix "$plugin/agent" run build >/dev/null

printf '== build a change, then review it on the real file\n'
nvim --clean --headless -l "$here/review-buffers.lua"

cat "$NVIME_E2E_OUT"
for marker in BUILT PANE BUFFER TREESITTER MARKS LSP HUNKS UNIFIED ROUNDTRIP CLOSED; do
  grep -q "^$marker" "$NVIME_E2E_OUT" || { echo "missing: $marker"; exit 1; }
done
grep -q '^BUFFER filetype=lua buftype="" modifiable=false' "$NVIME_E2E_OUT" ||
  { echo 'the pane was not a normal read-only lua buffer'; exit 1; }
grep -q '^PANE showing=file' "$NVIME_E2E_OUT" ||
  { echo 'the pane did not open on the real file'; exit 1; }

printf 'PASS — the review pane is the clone’s own file (%s)\n' "$work"
