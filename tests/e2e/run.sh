#!/usr/bin/env bash
# The one way to run nvime's live end-to-end scenarios.
#
#   tests/e2e/run.sh                  every scenario
#   tests/e2e/run.sh cold-start       just these
#   tests/e2e/run.sh --keep           keep the scratch root either way
#
# Each scenario drives real Neovim against the real `claude` CLI, so a full run
# costs tokens and minutes and needs a subscription login. CI never runs this.
#
# Per invocation the runner builds the sidecar once, then gives every scenario
# its own directory with all four XDG homes pointed inside it — a scenario must
# never read or write the developer's own config, data, state or cache.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(dirname "$(dirname "$here")")"

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

usage() {
  cat <<'TEXT'
usage: tests/e2e/run.sh [--keep] [--list] [scenario ...]

  --keep   keep the scratch root even when everything passes
  --list   print the scenario names and their default timeouts

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

default_timeout_for() {
  printf '%s\n' "$SCENARIOS" | awk -F: -v want="$1" 'NF && $1 == want { print $2 }'
}

# The caller's override for one scenario, else its default.
timeout_for() {
  local name="$1" var value
  var="NVIME_E2E_TIMEOUT_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  eval "value=\${$var:-}"
  if [ -n "$value" ]; then
    case "$value" in
      '' | *[!0-9]*)
        echo "run.sh: $var must be a whole number of seconds, got '$value'" >&2
        exit 2
        ;;
    esac
    printf '%s' "$value"
    return
  fi
  default_timeout_for "$name"
}

keep=0
wanted=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1 ;;
    --list)
      printf '%s\n' "$SCENARIOS" | awk -F: 'NF { printf "%-16s %ss\n", $1, $2 }'
      exit 0
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
      if [ ! -x "$here/$1.sh" ]; then
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
need nvim
need node
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

# A login check without spending a token can only be a heuristic: it looks for
# the credential the CLI stores. nvime is subscription-only — there is no API
# key in this product, and nothing here reads or sets one.
logged_in() {
  [ "${NVIME_E2E_SKIP_LOGIN_CHECK:-0}" = 1 ] && return 0
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

echo "== building the sidecar once"
npm --prefix "$plugin/agent" run build >"$root/build.log" 2>&1 || {
  echo "run.sh: the sidecar build failed — see $root/build.log" >&2
  exit 1
}

# ---- run one scenario ------------------------------------------------------

# Job control, so every backgrounded scenario leads its OWN process group and a
# timeout can take its detached runner down with it: a big-change build
# outlives the editor that started it, and a leaked one keeps spending tokens.
set -m

group_kill() {
  kill "-$1" -- "-$2" 2>/dev/null || true
}

# Waits out `pid` for at most `limit` seconds, leaving the exit status — or
# 124 for a missed deadline, the way `timeout` reports one — in `scenario_status`.
# Not a command substitution: `wait` only works on the shell's own children.
scenario_status=0
wait_bounded() {
  local pid="$1" limit="$2" waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      group_kill TERM "$pid"
      sleep 5
      group_kill KILL "$pid"
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
  "$here/$name.sh" >"$console" 2>&1 &
  pid=$!
  wait_bounded "$pid" "$limit"
  status="$scenario_status"
  # Nothing of this scenario may outlive it, timeout or not.
  group_kill KILL "$pid"
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
  [ "$verdict" = PASS ] || tail -n 20 "$console" | sed 's/^/   | /'
  echo "== $name $verdict in ${elapsed}s"
  results="$results$name|$verdict|$elapsed|$console
"
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
