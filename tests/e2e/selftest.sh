#!/usr/bin/env bash
# The runner's own self-test: does `run.sh` really stop everything a scenario
# started — and only that?
#
# It matters because a big-change build runner is spawned `detached: true` —
# setsid, reparented to init, in a process group of its own — so killing the
# scenario's group does NOT reach it, and a leaked one drives the real CLI to
# completion on its own money. It matters in the other direction too: the store
# keeps naming a runner after it exits, so signalling a pid without checking the
# claim behind it kills whatever recycled that number.
#
# Stub scenarios only: no nvim, no sidecar, no `claude`, no tokens. Each stub
# has the same shape as a real one — a child inside the scenario's group, and a
# setsid'd grandchild recorded in a session store the way a runner records
# itself, heartbeat and all. Run it with `tests/e2e/run.sh --selftest`.
set -euo pipefail

# Job control, so the interrupt test means something: without it a
# non-interactive shell starts every background job with SIGINT already
# ignored, and `trap … INT` inside run.sh could never fire however correct it
# is. A terminal's Ctrl-C, which is what this stands in for, has no such
# problem — it signals the foreground group directly.
set -m

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"
lab="$(mktemp -d "${TMPDIR:-/tmp}/nvime-e2e-selftest-XXXXXX")"
export NVIME_E2E_SELFTEST_LAB="$lab"

# Bystanders outlive their stub by design, and a FAILING kill assertion leaves
# its runners and children alive — the one case where they must be swept. A
# script whose whole subject is not leaking processes may not leak any itself.
# shellcheck disable=SC2329  # invoked from the traps below
cleanup() {
  local path pid pgid root
  for path in "$lab"/*.pid; do
    [ -f "$path" ] || continue
    pid="$(cat "$path")"
    [ -n "$pid" ] || continue
    # The group form only for a process that really leads one, so this cannot
    # signal a group that merely reuses the number — the same rule run.sh keeps.
    # `|| true`: most of these are already dead by now, and `ps` failing on one
    # must not abort the trap under `set -e` — that would leave the rest alive.
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    kill -KILL "$pid" 2>/dev/null || true
  done
  # Most stub scenarios fail on purpose, so run.sh keeps their scratch roots.
  # Only paths it printed, and only ones that look like its own.
  # `|| true` on the whole pipeline: `pipefail` would turn a grep that matches
  # nothing into a failed trap, and the lab would survive.
  {
    grep -h '^scratch kept at ' "$lab"/*.log 2>/dev/null | sed 's/^scratch kept at //' | sort -u |
      while IFS= read -r root; do
        case "$root" in
          */nvime-e2e-*) rm -rf "$root" ;;
        esac
      done
  } || true
  rm -rf "$lab"
}
# EXIT alone is not enough: a signal kills the shell without running it, and
# then the stubs this script started are exactly what is left behind.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

failures=0
note() { printf '\n== %s\n' "$1"; }
ok() { printf '   ok   %s\n' "$1"; }
bad() {
  printf '   FAIL %s\n' "$1"
  failures=$((failures + 1))
}

alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

read_pid() {
  [ -f "$1" ] || return 0
  cat "$1"
}

# One check: `want` is 'live' or 'gone', and the label names the process.
must_be() {
  local want="$1" pid="$2" label="$3"
  if [ -z "$pid" ]; then
    bad "$label was never recorded"
    return
  fi
  if alive "$pid"; then
    if [ "$want" = live ]; then ok "$label $pid is still there"; else bad "$label $pid survived"; fi
    return
  fi
  if [ "$want" = gone ]; then ok "$label $pid is gone"; else bad "$label $pid was killed"; fi
}

must_exit() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then ok "$label exited $got"; else bad "$label exited $got, wanted $want"; fi
}

must_say() {
  local path="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$path"; then ok "$label"; else bad "$label — not in $path"; fi
}

# ---- the stubs -------------------------------------------------------------

# Shared by every stub: writes the store records a real runner writes, the same
# way it writes them. Atomically — the product uses tmp+rename, and the reaper
# now treats an unparseable record as a failure rather than as "no runners".
cat >"$lab/store.sh" <<'HELPERS'
now_ms() { echo $(( $(date +%s) * 1000 )); }

# `uname -n`, not `hostname`: the latter is not installed everywhere, and a
# record whose host does not match Node's `os.hostname()` is never reapable.
# write_lock <dir> <pid> <heartbeat-ms>
write_lock() {
  printf '{"owner":"stub","pid":%s,"host":"%s","what":"build","startedAt":%s,"heartbeatAt":%s}\n' \
    "$2" "$(uname -n)" "$3" "$3" >"$1/lock.json.tmp"
  mv "$1/lock.json.tmp" "$1/lock.json"
}

# write_session <dir> <pid>
write_session() {
  printf '{"id":"stub","runner":{"pid":%s,"startedAt":0}}\n' "$2" >"$1/session.json.tmp"
  mv "$1/session.json.tmp" "$1/session.json"
}

store_dir() {
  local dir="$NVIME_E2E_WORK/data/nvim/nvime/big/repo-deadbeef/$1"
  mkdir -p "$dir"
  echo "$dir"
}
HELPERS

cat >"$lab/wedge.sh" <<'STUB'
#!/usr/bin/env bash
# A wedged scenario: one child in this scenario's own process group, and one
# setsid'd grandchild recorded — and heartbeated — exactly as a live detached
# build runner records itself.
set -euo pipefail
name="$(basename "$0" .sh)"
lab="$NVIME_E2E_SELFTEST_LAB"
. "$lab/store.sh"

sleep 600 &
echo "$!" >"$lab/$name.child.pid"

setsid sleep 600 &
grand=$!
echo "$grand" >"$lab/$name.runner.pid"

# The proof that a group kill cannot reach it: its process group is not ours.
{
  echo "scenario_pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
  echo "runner_pgid=$(ps -o pgid= -p "$grand" | tr -d ' ')"
  echo "runner_ppid=$(ps -o ppid= -p "$grand" | tr -d ' ')"
} >"$lab/$name.groups"

store="$(store_dir live)"
write_session "$store" "$grand"
write_lock "$store" "$grand" "$(now_ms)"
# A real runner refreshes its claim every few seconds; a claim that goes stale
# is exactly what tells the reaper to leave the pid alone.
while true; do
  sleep 2
  write_lock "$store" "$grand" "$(now_ms)"
done &

echo "$name: child and detached runner up"
sleep 600
STUB

cat >"$lab/stalepid.sh" <<'STUB'
#!/usr/bin/env bash
# A scenario that PASSES, leaving behind exactly what a finished build leaves:
# records naming pids that are no longer its runners. Both stand-ins must
# survive — signalling either is the recycled-pid kill.
#
# They are setsid'd on purpose: a recycled pid is some OTHER process on the
# machine, not a child of this scenario. Leaving them in the scenario's group
# would conflate "must not be signalled" with "must be swept", and freeze the
# group sweep out.
set -euo pipefail
name="$(basename "$0" .sh)"
lab="$NVIME_E2E_SELFTEST_LAB"
. "$lab/store.sh"

# A record with no claim at all: what the store looks like after a runner exits.
setsid sleep 500 &
echo "$!" >"$lab/$name.bystander.noclaim.pid"
write_session "$(store_dir noclaim)" "$!"

# A claim whose heartbeat stopped a minute ago: the runner is long gone.
setsid sleep 500 &
echo "$!" >"$lab/$name.bystander.stale.pid"
stale="$(store_dir stale)"
write_session "$stale" "$!"
write_lock "$stale" "$!" "$(( $(now_ms) - 60000 ))"

echo "$name: two recorded-but-dead runners left behind"
STUB

cat >"$lab/orphan.sh" <<'STUB'
#!/usr/bin/env bash
# A wedged scenario whose runner does NOT go down on SIGTERM — standing in for
# a graceful abort that outlasts the grace — and which owns a child, the way a
# real runner owns the `claude` the SDK spawned. Killing the runner's pid alone
# orphans that child, and an orphaned `claude` keeps spending.
set -euo pipefail
name="$(basename "$0" .sh)"
lab="$NVIME_E2E_SELFTEST_LAB"
. "$lab/store.sh"

setsid bash -c '
  trap "" TERM
  sleep 600 &
  echo "$!" >"$NVIME_E2E_SELFTEST_LAB/orphan.child.pid"
  sleep 600
' &
runner=$!
echo "$runner" >"$lab/$name.runner.pid"

store="$(store_dir live)"
write_session "$store" "$runner"
write_lock "$store" "$runner" "$(now_ms)"
while true; do
  sleep 2
  write_lock "$store" "$runner" "$(now_ms)"
done &

# The child is written by the runner itself; wait for it before wedging, so the
# topology under test really exists.
waited=0
while [ ! -f "$lab/orphan.child.pid" ] && [ "$waited" -lt 10 ]; do
  sleep 1
  waited=$((waited + 1))
done
echo "$name: a TERM-proof runner with a child of its own"
sleep 600
STUB

cat >"$lab/leftover.sh" <<'STUB'
#!/usr/bin/env bash
# A scenario that PASSES but leaves something of its own behind — a wedged
# editor, a sidecar that did not exit. It is in this scenario's process group,
# and nothing else will ever stop it.
set -euo pipefail
name="$(basename "$0" .sh)"
lab="$NVIME_E2E_SELFTEST_LAB"

sleep 600 &
echo "$!" >"$lab/$name.leftover.pid"
echo "$name: left a child behind in my own group"
STUB

printf '#!/usr/bin/env bash\nexit 0\n' >"$lab/quickpass.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$lab/notimeout.sh"
chmod +x "$lab"/*.sh

cp "$lab/wedge.sh" "$lab/wedge2.sh"
chmod +x "$lab/wedge2.sh"

printf 'process.stderr.write("runner-pids: exploded\\n");\nprocess.exit(3);\n' >"$lab/broken-runtime.mjs"
printf 'this is not javascript {{{\n' >"$lab/broken-syntax.mjs"

cat >"$lab/scenarios.txt" <<'TABLE'
wedge:5
wedge2:600
orphan:5
stalepid:60
leftover:60
quickpass:60
notimeout
TABLE

run_stub() {
  NVIME_E2E_SELFTEST_DIR="$lab" "$here/run.sh" "$@"
}

# ---- 1. a missed deadline takes the live detached runner with it -----------

note 'a scenario that misses its deadline loses its heartbeating detached runner'
run_stub wedge >"$lab/wedge.log" 2>&1 || true
cat "$lab/wedge.groups" 2>/dev/null || echo '(no group record — the stub never started)'

must_say "$lab/wedge.log" '^== wedge TIMEOUT' 'reported TIMEOUT'
must_be gone "$(read_pid "$lab/wedge.child.pid")" 'the in-group child'
must_be gone "$(read_pid "$lab/wedge.runner.pid")" 'the detached runner'

# ---- 2. Ctrl-C on the runner leaves nothing behind -------------------------

note 'interrupting the runner stops the scenario and its detached runner'
rm -f "$lab/wedge2.child.pid" "$lab/wedge2.runner.pid"
# Started directly, not through `run_stub`: a function backgrounded runs in a
# subshell, and the interrupt has to reach run.sh itself.
NVIME_E2E_SELFTEST_DIR="$lab" "$here/run.sh" wedge2 >"$lab/wedge2.log" 2>&1 &
runner_sh=$!

waited=0
while [ ! -f "$lab/wedge2.runner.pid" ] && [ "$waited" -lt 30 ]; do
  sleep 1
  waited=$((waited + 1))
done
sleep 1

kill -INT "$runner_sh" 2>/dev/null || true
code=0
wait "$runner_sh" 2>/dev/null || code=$?

must_exit 130 "$code" 'run.sh'
must_say "$lab/wedge2.log" 'scratch kept at' 'printed the scratch root'
must_be gone "$runner_sh" 'run.sh itself'
must_be gone "$(read_pid "$lab/wedge2.child.pid")" 'the in-group child'
must_be gone "$(read_pid "$lab/wedge2.runner.pid")" 'the detached runner'

# ---- 3. a killed runner takes the process it spawned with it ---------------

note 'a runner that will not go down gracefully does not orphan its child'
run_stub orphan >"$lab/orphan.log" 2>&1 || true
must_say "$lab/orphan.log" '^== orphan TIMEOUT' 'reported TIMEOUT'
must_be gone "$(read_pid "$lab/orphan.runner.pid")" 'the TERM-proof runner'
must_be gone "$(read_pid "$lab/orphan.child.pid")" "the runner's own child"

# ---- 4. a passing scenario leaves nothing of its own behind ----------------

note 'a passing scenario is swept, not just its detached runners'
code=0
run_stub leftover >"$lab/leftover.log" 2>&1 || code=$?
must_exit 0 "$code" 'the passing scenario'
must_say "$lab/leftover.log" '^== leftover PASS' 'reported PASS'
must_be gone "$(read_pid "$lab/leftover.leftover.pid")" 'what it left in its own group'

# ---- 5. a record without a live claim is never signalled -------------------

note 'a passing scenario does not signal the pids its finished runners left behind'
code=0
run_stub stalepid >"$lab/stalepid.log" 2>&1 || code=$?
must_exit 0 "$code" 'the passing scenario'
must_say "$lab/stalepid.log" '^== stalepid PASS' 'reported PASS'
must_be live "$(read_pid "$lab/stalepid.bystander.noclaim.pid")" 'the pid a claimless record names'
must_be live "$(read_pid "$lab/stalepid.bystander.stale.pid")" 'the pid a stale claim names'

# ---- 6. a reaper that cannot read the store is never a pass ----------------

note 'a broken reaper is reported, not swallowed'
code=0
NVIME_E2E_PIDS_HELPER="$lab/broken-runtime.mjs" run_stub quickpass >"$lab/blind.log" 2>&1 || code=$?
must_exit 1 "$code" 'the run'
must_say "$lab/blind.log" 'WARNING the runner reaper failed' 'warned loudly'
must_say "$lab/blind.log" 'exploded' "let the helper's own stderr through"
must_say "$lab/blind.log" 'BLIND' 'refused to call it a pass'

note 'a reaper that does not parse is caught before anything is spent'
code=0
NVIME_E2E_PIDS_HELPER="$lab/broken-syntax.mjs" run_stub quickpass >"$lab/nocheck.log" 2>&1 || code=$?
must_exit 2 "$code" 'preflight'
must_say "$lab/nocheck.log" 'does not parse' 'said why'

# ---- 7. names, deadlines, and the mirrored staleness rule ------------------

note 'an unlisted scenario name is refused'
code=0
run_stub not-a-scenario >"$lab/unlisted.log" 2>&1 || code=$?
must_exit 2 "$code" 'an unlisted name'

note 'a scenario the table gives no deadline is a runner bug, not a free pass'
code=0
run_stub notimeout >"$lab/notimeout.log" 2>&1 || code=$?
must_exit 2 "$code" 'a scenario with no deadline'
must_say "$lab/notimeout.log" 'no deadline' 'said why'

note 'a non-numeric deadline override is refused'
code=0
NVIME_E2E_TIMEOUT_WEDGE=abc run_stub wedge >"$lab/badtimeout.log" 2>&1 || code=$?
must_exit 2 "$code" 'a bad override'
must_say "$lab/badtimeout.log" 'NVIME_E2E_TIMEOUT_WEDGE' 'named the variable'

note 'the mirrored staleness rule still matches the product'
# `|| true`: a file that does not name it at all is a drift report, not a crash.
stale_ms() { grep -oE 'LOCK_STALE_MS = [0-9_]+' "$1" 2>/dev/null | head -1 | sed 's/.*= //; s/_//g' || true; }
product="$(stale_ms "$plugin/agent/src/bigstore.ts")"
mirror="$(stale_ms "$here/runner-pids.mjs")"
if [ -n "$product" ] && [ "$product" = "$mirror" ]; then
  ok "LOCK_STALE_MS is ${mirror}ms in both"
else
  bad "LOCK_STALE_MS drifted: bigstore.ts says '${product}', runner-pids.mjs says '${mirror}'"
fi

# ---- verdict ---------------------------------------------------------------

echo
if [ "$failures" = 0 ]; then
  echo 'selftest: the runner stops everything it starts, and nothing it did not'
  exit 0
fi
echo "selftest: $failures check(s) failed"
exit 1
