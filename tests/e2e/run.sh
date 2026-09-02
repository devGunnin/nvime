#!/usr/bin/env bash
# The one way to run nvime's live end-to-end scenarios.
#
#   tests/e2e/run.sh                  every scenario
#   tests/e2e/run.sh cold-start       just these
#   tests/e2e/run.sh --keep           keep the scratch root either way
#   tests/e2e/run.sh --selftest       prove the runner's own kill paths, no tokens
#
# Each scenario drives real Neovim against the real `claude` CLI, so a full run
# costs tokens and minutes and needs a subscription login. CI never runs this.
#
# Per invocation the runner builds the sidecar once, then gives every scenario
# its own directory with all four XDG homes pointed inside it — a scenario must
# never read or write NVIME's own config, data, state or cache. `~/.claude` is
# NOT isolated (that is where the subscription login lives), so a scenario's
# prompts and transcripts do land in the developer's real claude directory.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"

# Self-test seam: `selftest.sh` runs its stub scenarios through THIS script,
# with its own scenario directory and table, so the kill paths are proven in the
# real runner rather than in a copy of it. Never set by a real run.
selftest_dir="${NVIME_E2E_SELFTEST_DIR:-}"
scenario_dir="$here"
pids_helper="$here/runner-pids.mjs"

# Scenario name, then its default timeout in seconds. One flat list because
# bash 3.2 (still the system bash on macOS) has no associative arrays.
# Deadlines, not estimates: each observed run is well under a minute, and these
# leave room for a slow model or a slow machine before calling it wedged.
SCENARIOS="
cold-start:900
prompt-keys:600
debug-bundle:900
review-buffers:900
rebase-merge:1200
detached-build:1200
"

if [ -n "$selftest_dir" ]; then
  scenario_dir="$selftest_dir"
  SCENARIOS="$(cat "$selftest_dir/scenarios.txt")"
  # Self-test only, so a real run cannot be pointed at a helper that lies about
  # what is still running.
  pids_helper="${NVIME_E2E_PIDS_HELPER:-$pids_helper}"
fi

usage() {
  cat <<'TEXT'
usage: tests/e2e/run.sh [--keep] [--list] [scenario ...]
       tests/e2e/run.sh --selftest

  --keep      keep the scratch root even when everything passes
  --list      print the scenario names and their default timeouts
  --selftest  run the runner's own stub-based self-test (spends no tokens)

Environment:
  NVIME_E2E_MODEL              model for every scenario (default: sonnet)
  NVIME_E2E_TIMEOUT_<NAME>     seconds for one scenario, NAME upper-cased
                               with '-' as '_' (e.g. NVIME_E2E_TIMEOUT_COLD_START)
  NVIME_E2E_SKIP_LOGIN_CHECK=1 skip the login pre-check (it is a heuristic)
TEXT
}

all_names() {
  printf '%s\n' "$SCENARIOS" | awk -F: 'NF { print $1 }'
}

is_scenario() {
  all_names | grep -qx -- "$1"
}

# The table's own entry for `name`. Empty means the table is wrong, not that the
# scenario has no deadline — every caller treats that as a runner bug.
default_timeout_for() {
  printf '%s\n' "$SCENARIOS" | awk -F: -v want="$1" 'NF && $1 == want { print $2 }'
}

# The caller's override for one scenario, else its default. Exits rather than
# answering with something a comparison would silently accept.
timeout_for() {
  local name="$1" var value
  var="NVIME_E2E_TIMEOUT_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    value="$(default_timeout_for "$name")"
    if [ -z "$value" ]; then
      echo "run.sh: no deadline for '$name' — add it to the SCENARIOS table." >&2
      exit 2
    fi
    printf '%s' "$value"
    return
  fi
  case "$value" in
    *[!0-9]* | '')
      echo "run.sh: $var must be a whole number of seconds, got '$value'" >&2
      exit 2
      ;;
  esac
  printf '%s' "$value"
}

keep=0
wanted=""
argc=$#
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1 ;;
    --list)
      printf '%s\n' "$SCENARIOS" | awk -F: 'NF { printf "%-16s %ss\n", $1, $2 }'
      exit 0
      ;;
    --selftest)
      # It runs its own scenarios with its own deadlines, so every other
      # argument — before it or after it — would be silently discarded.
      if [ "$argc" -ne 1 ]; then
        echo "run.sh: --selftest takes no other arguments" >&2
        exit 2
      fi
      exec "$here/selftest.sh"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "run.sh: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      # Against the table, not the filesystem: a scenario the table does not
      # name has no deadline, and running it unbounded is the one thing the
      # runner exists to prevent.
      if ! is_scenario "$1"; then
        echo "run.sh: no scenario named '$1' (try --list)" >&2
        exit 2
      fi
      wanted="$wanted $1"
      ;;
  esac
  shift
done
[ -n "$wanted" ] || wanted="$(all_names)"

# ---- preflight: refuse early, in plain words -------------------------------

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "run.sh: '$1' is not on PATH — the e2e scenarios need it." >&2
    exit 2
  }
}
need node

# The reaper is what stands between a wedged build and unbounded spend, and
# nothing else in the repo compiles it. A syntax error must not be discovered
# at teardown, after the tokens are gone.
if ! node --check "$pids_helper"; then
  echo "run.sh: $pids_helper does not parse — the runner reaper would be blind." >&2
  exit 2
fi

# Every deadline is resolved here, before anything is built or spent: a bad
# override must not surface minutes into a run.
for name in $wanted; do
  if [ ! -x "$scenario_dir/$name.sh" ]; then
    echo "run.sh: the table names '$name' but $scenario_dir/$name.sh is not executable." >&2
    exit 2
  fi
  timeout_for "$name" >/dev/null
done

if [ -z "$selftest_dir" ]; then
  need nvim
  need npm
  need git

  if [ ! -d "$plugin/agent/node_modules" ]; then
    echo "run.sh: the sidecar's dependencies are not installed — run 'npm --prefix agent ci' first." >&2
    exit 2
  fi

  if ! command -v claude >/dev/null 2>&1; then
    cat >&2 <<'TEXT'
run.sh: the `claude` CLI is not on PATH.

The e2e scenarios drive the real CLI through your existing subscription login.
Install it and run `claude` once to log in, then try again.
TEXT
    exit 2
  fi
fi

# A login check without spending a token can only be a heuristic: it looks for
# the credential the CLI stores. nvime is subscription-only — there is no API
# key in this product, and nothing here reads or sets one.
logged_in() {
  [ "${NVIME_E2E_SKIP_LOGIN_CHECK:-0}" = 1 ] && return 0
  [ -n "$selftest_dir" ] && return 0
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -f "$config_dir/.credentials.json" ] && return 0
  command -v security >/dev/null 2>&1 &&
    security find-generic-password -s 'Claude Code-credentials' >/dev/null 2>&1 && return 0
  return 1
}

if ! logged_in; then
  cat >&2 <<'TEXT'
run.sh: `claude` does not look logged in.

The e2e scenarios drive it through your subscription. Run `claude`, log in,
then try again. If you are logged in some way this check cannot see, re-run
with NVIME_E2E_SKIP_LOGIN_CHECK=1.
TEXT
  exit 2
fi

export NVIME_E2E_MODEL="${NVIME_E2E_MODEL:-sonnet}"

# ---- scratch root: this run's alone ----------------------------------------

root="${TMPDIR:-/tmp}/nvime-e2e-$$-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$root"

if [ -z "$selftest_dir" ]; then
  echo "== building the sidecar once"
  npm --prefix "$plugin/agent" run build >"$root/build.log" 2>&1 || {
    echo "run.sh: the sidecar build failed — see $root/build.log" >&2
    exit 1
  }
  # Told once, so the scenarios skip their own build. A wrapper run by hand
  # still builds for itself.
  export NVIME_E2E_BUILT=1
fi

# ---- stopping a scenario, all of it -----------------------------------------

# Job control, so every backgrounded scenario leads its OWN process group.
set -m

group_kill() {
  kill "-$1" -- "-$2" 2>/dev/null || true
}

# Whether any process is still in group `pgid`. The leader itself may be long
# gone — what matters is whether the group still holds anything to stop.
group_alive() {
  [ -n "$1" ] || return 1
  ps -eo pgid= 2>/dev/null | tr -d ' ' | grep -qx -- "$1"
}

# A vouched runner leads its own session, so its process group id IS its pid,
# and that group holds exactly its own descendants — the `claude` the SDK
# spawned included. Checked rather than assumed: a pgid that is not the pid
# would make the group somebody else's, and this ends in a SIGKILL.
runner_group_of() {
  local pid="$1" pgid
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [ -n "$pgid" ] && [ "$pgid" = "$pid" ]; then
    echo "$pid"
  fi
}

anything_alive() {
  local pgid="$1" others="$2" one
  if group_alive "$pgid"; then
    return 0
  fi
  for one in $others; do
    if kill -0 "$one" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Set when the reaper could not read the store. A run that cannot see its own
# runners has no token guard, and must never be reported as a pass.
reaper_blind=0

# Everything one scenario started: its whole process group, and every build
# runner outside it — those are setsid'd and reparented to init, so the group
# does not contain them and a group kill alone leaves them spending.
#
# Only LIVE runners are signalled. The helper vouches for a pid off the store's
# own claim, because `session.runner` outlives the process it names and the
# number is free for reuse the moment the runner exits.
#
# Pids and their groups are read ONCE up front — a runner clears its record as
# it goes down, and a dead leader can no longer name the group its orphan is in.
reap_scenario() {
  local pid="$1" work="$2" runners="" runner leaders="" leader status=0
  if [ -d "$work" ]; then
    # stderr is NOT swallowed: the helper names the record it could not read.
    runners="$(node "$pids_helper" "$work")" || status=$?
    if [ "$status" != 0 ]; then
      reaper_blind=1
      echo "run.sh: WARNING the runner reaper failed (exit $status) — a detached build may still be running and spending." >&2
    fi
  fi
  for runner in $runners; do
    leaders="$leaders $(runner_group_of "$runner")"
  done

  # TERM the runner itself, not its group: the graceful path is the runner
  # aborting its own turn and releasing the claim.
  if [ -n "$pid" ]; then
    group_kill TERM "$pid"
  fi
  for runner in $runners; do
    kill -TERM "$runner" 2>/dev/null || true
  done

  if ! anything_alive "$pid" "$runners"; then
    return
  fi
  sleep 2
  if [ -n "$pid" ]; then
    group_kill KILL "$pid"
  fi
  for runner in $runners; do
    kill -KILL "$runner" 2>/dev/null || true
  done
  # And the runner's own group, so a `claude` that outlived it is not orphaned
  # and left spending. Sampled before the TERM on purpose: once the leader is
  # gone it can no longer name the group its orphan is in — which is the case
  # this exists for. The cost is that nothing pins the id in between, and a
  # recycled pgid would take a stranger's whole group, not one stray process.
  # No fix without giving up the orphan: re-checking at kill time finds the
  # leader already gone exactly when the sweep is needed.
  for leader in $leaders; do
    group_kill KILL "$leader"
  done
}

# The scenario in flight, for the signal handlers. Empty between scenarios, so
# a handler knows whether there is anything left to stop.
current_pid=""
current_work=""

# shellcheck disable=SC2329  # invoked from the traps below
stop_everything() {
  local why="$1"
  echo
  echo "run.sh: $why — stopping the scenario and any build it started"
  reap_scenario "$current_pid" "$current_work"
  current_pid=""
  echo "scratch kept at $root"
}

# shellcheck disable=SC2329  # invoked from the traps below
on_signal() {
  local why="$1" code="$2"
  trap - INT TERM EXIT
  stop_everything "$why"
  exit "$code"
}

# Ctrl-C is exactly the gesture someone reaches for when a run is costing too
# much, and `set -m` above means the terminal's own SIGINT never reaches the
# scenario's group. Without these the whole tree — nvim, the sidecar, the CLI,
# the detached runner — keeps running.
trap 'on_signal interrupted 130' INT
trap 'on_signal terminated 143' TERM
trap 'if [ -n "$current_pid" ]; then stop_everything "exiting early"; fi' EXIT

# Waits out `pid` for at most `limit` seconds, leaving the exit status — or
# 124 for a missed deadline, the way `timeout` reports one — in `scenario_status`,
# and whether it already swept the scenario's group in `scenario_reaped`.
# Not a command substitution: `wait` only works on the shell's own children.
scenario_status=0
scenario_reaped=0
wait_bounded() {
  local pid="$1" limit="$2" work="$3" waited=0
  scenario_reaped=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      reap_scenario "$pid" "$work"
      scenario_reaped=1
      wait "$pid" 2>/dev/null || true
      scenario_status=124
      return
    fi
    sleep 2
    waited=$((waited + 2))
  done
  scenario_status=0
  wait "$pid" 2>/dev/null || scenario_status=$?
}

# ---- run the scenarios -----------------------------------------------------

results=""
failed=0

for name in $wanted; do
  limit="$(timeout_for "$name")"
  work="$root/$name"
  console="$work/console.log"
  mkdir -p "$work"

  # All four homes, inside this scenario's own directory. nvime writes its
  # big-change store under XDG_DATA_HOME and its debug log under
  # XDG_STATE_HOME; neither may be the developer's.
  export NVIME_E2E_WORK="$work"
  export XDG_CONFIG_HOME="$work/config"
  export XDG_DATA_HOME="$work/data"
  export XDG_STATE_HOME="$work/state"
  export XDG_CACHE_HOME="$work/cache"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"

  echo "== $name (timeout ${limit}s)"
  started="$(date +%s)"
  reaper_blind=0
  # A sentinel started INSIDE the scenario's own process group (`set +m`, so it
  # is not given a group of its own), outliving the deadline. It holds the
  # group's id reserved after the scenario exits: a group whose members are all
  # gone can have its id reused, and a sweep would then hit a stranger. The
  # sweep below kills it along with anything else left in there.
  (
    set +m
    sleep $((limit + 600)) &
    exec "$scenario_dir/$name.sh"
  ) >"$console" 2>&1 &
  pid=$!
  current_pid="$pid"
  current_work="$work"
  wait_bounded "$pid" "$limit" "$work"
  status="$scenario_status"
  # Whatever the verdict: nothing the scenario started may outlive it — not a
  # wedged editor left in its group, not a build runner outside it. On the
  # deadline path the group is already swept, and with it the sentinel that
  # pinned its id: naming it again would signal whatever now holds that number.
  if [ "$scenario_reaped" = 1 ]; then
    reap_scenario "" "$work"
  else
    reap_scenario "$pid" "$work"
  fi
  current_pid=""
  elapsed=$(($(date +%s) - started))

  if [ "$status" = 0 ]; then
    verdict=PASS
  elif [ "$status" = 124 ]; then
    verdict=TIMEOUT
    failed=1
  else
    verdict=FAIL
    failed=1
  fi
  # A scenario whose runners could not be read is not a pass, whatever the
  # driver said: nobody knows whether a build is still spending.
  if [ "$reaper_blind" = 1 ]; then
    verdict=BLIND
    failed=1
  fi
  # A driver that dies takes its wrapper's `cat` of the report with it, so the
  # console alone can be just the banner. Show both.
  if [ "$verdict" != PASS ]; then
    tail -n 20 "$console" | sed 's/^/   | /'
    if [ -s "$work/report.txt" ]; then
      tail -n 10 "$work/report.txt" | sed 's/^/   > /'
    fi
  fi
  echo "== $name $verdict in ${elapsed}s"
  results="$results$name|$verdict|$elapsed|$console
"
  # BLIND means nobody knows whether a build from this scenario is still
  # spending. Starting the next one would spend more on top of that.
  if [ "$verdict" = BLIND ]; then
    echo "run.sh: stopping here — the cost guard is broken, so no further scenario is started." >&2
    break
  fi
done

# ---- summary ---------------------------------------------------------------

echo
printf '%-16s %-8s %8s  %s\n' SCENARIO RESULT SECONDS OUTPUT
printf '%s' "$results" | awk -F'|' 'NF { printf "%-16s %-8s %8s  %s\n", $1, $2, $3, $4 }'
echo

if [ "$failed" = 0 ] && [ "$keep" = 0 ]; then
  rm -rf "$root"
  echo "all scenarios passed"
  exit 0
fi

echo "scratch kept at $root"
if [ "$failed" = 0 ]; then
  exit 0
fi
exit 1
