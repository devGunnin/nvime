#!/usr/bin/env bash
# The runner's own self-test: does `run.sh` really stop everything a scenario
# started, on a missed deadline and on Ctrl-C?
#
# It matters because a big-change build runner is spawned `detached: true` —
# setsid, reparented to init, in a process group of its own — so killing the
# scenario's group does NOT reach it, and a leaked one drives the real CLI to
# completion on its own money.
#
# Stub scenarios only: no nvim, no sidecar, no `claude`, no tokens. Each stub
# has the same shape as a real one — a child inside the scenario's group, and a
# setsid'd grandchild recorded in a session store the way a runner records
# itself. Run it with `tests/e2e/run.sh --selftest`.
set -euo pipefail

# Job control, so the interrupt test means something: without it a
# non-interactive shell starts every background job with SIGINT already
# ignored, and `trap … INT` inside run.sh could never fire however correct it
# is. A terminal's Ctrl-C, which is what this stands in for, has no such
# problem — it signals the foreground group directly.
set -m

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab="$(mktemp -d "${TMPDIR:-/tmp}/nvime-e2e-selftest-XXXXXX")"
export NVIME_E2E_SELFTEST_LAB="$lab"
trap 'rm -rf "$lab"' EXIT

failures=0
note() { printf '\n== %s\n' "$1"; }
ok() { printf '   ok   %s\n' "$1"; }
bad() {
  printf '   FAIL %s\n' "$1"
  failures=$((failures + 1))
}

# `pid` is a live process. A pid file that never appeared is its own failure.
alive() {
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# One check: `want` is 'live' or 'gone', and the label names the process.
must_be() {
  local want="$1" pid="$2" label="$3"
  if alive "$pid"; then
    if [ "$want" = live ]; then ok "$label $pid is still there"; else bad "$label $pid survived"; fi
    return
  fi
  if [ "$want" = gone ]; then ok "$label $pid is gone"; else bad "$label $pid died early"; fi
}

# One check on a command's exit status.
must_exit() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then ok "$label exited $got"; else bad "$label exited $got, wanted $want"; fi
}

# One check on the runner's output.
must_say() {
  local path="$1" pattern="$2" label="$3"
  if grep -q "$pattern" "$path"; then ok "$label"; else bad "$label — not in $path"; fi
}

read_pid() {
  local path="$1"
  [ -f "$path" ] || return 0
  cat "$path"
}

# ---- the stubs -------------------------------------------------------------

cat >"$lab/wedge.sh" <<'STUB'
#!/usr/bin/env bash
# A stub scenario: one child in this scenario's own process group, and one
# setsid'd grandchild recorded in a session store exactly as a detached build
# runner records itself. Then it wedges.
set -euo pipefail
name="$(basename "$0" .sh)"
lab="$NVIME_E2E_SELFTEST_LAB"

sleep 600 &
echo "$!" >"$lab/$name.child.pid"

setsid sleep 600 &
grand=$!
echo "$grand" >"$lab/$name.runner.pid"

# The proof that the group kill cannot reach it: its process group is not ours.
{
  echo "scenario_pgid=$(ps -o pgid= -p $$ | tr -d ' ')"
  echo "runner_pgid=$(ps -o pgid= -p "$grand" | tr -d ' ')"
  echo "runner_ppid=$(ps -o ppid= -p "$grand" | tr -d ' ')"
} >"$lab/$name.groups"

store="$NVIME_E2E_WORK/data/nvim/nvime/big/repo-deadbeef/stub1"
mkdir -p "$store"
printf '{"id":"stub1","runner":{"pid":%s,"startedAt":0}}\n' "$grand" >"$store/session.json"

echo "$name: child and detached runner up"
sleep 600
STUB

# Two identical stubs: one for the deadline, one for the interrupt. Each names
# its own pid files from its own filename.
cp "$lab/wedge.sh" "$lab/wedge2.sh"
chmod +x "$lab/wedge.sh" "$lab/wedge2.sh"

printf '#!/usr/bin/env bash\nexit 0\n' >"$lab/notimeout.sh"
chmod +x "$lab/notimeout.sh"

cat >"$lab/scenarios.txt" <<'TABLE'
wedge:5
wedge2:600
notimeout
TABLE

run_stub() {
  NVIME_E2E_SELFTEST_DIR="$lab" "$here/run.sh" "$@"
}

# ---- 1. a missed deadline takes the detached runner with it ----------------

note 'a scenario that misses its deadline loses its detached runner too'
run_stub wedge >"$lab/wedge.log" 2>&1 || true
cat "$lab/wedge.groups" 2>/dev/null || echo '(no group record — the stub never started)'

child="$(read_pid "$lab/wedge.child.pid")"
runner="$(read_pid "$lab/wedge.runner.pid")"
if [ -z "$child" ] || [ -z "$runner" ]; then
  bad 'the stub never recorded its pids'
else
  must_say "$lab/wedge.log" '^== wedge TIMEOUT' 'reported TIMEOUT'
  must_be gone "$child" 'the in-group child'
  must_be gone "$runner" 'the detached runner'
fi

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

child="$(read_pid "$lab/wedge2.child.pid")"
runner="$(read_pid "$lab/wedge2.runner.pid")"
if [ -z "$child" ] || [ -z "$runner" ]; then
  bad 'the stub never recorded its pids'
else
  must_exit 130 "$code" 'run.sh'
  must_say "$lab/wedge2.log" 'scratch kept at' 'printed the scratch root'
  must_be gone "$runner_sh" 'run.sh itself'
  must_be gone "$child" 'the in-group child'
  must_be gone "$runner" 'the detached runner'
fi

# ---- 3. names and deadlines are validated before anything runs -------------

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

# ---- verdict ---------------------------------------------------------------

echo
if [ "$failures" = 0 ]; then
  echo 'selftest: the runner stops everything it starts'
  exit 0
fi
echo "selftest: $failures check(s) failed"
exit 1
