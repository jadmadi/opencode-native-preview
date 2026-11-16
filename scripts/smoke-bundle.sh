#!/usr/bin/env bash
# shellcheck disable=SC2086 # $run is empty or a command with its arguments, split on purpose
# The bundle's smoke test on a fresh box: smoke-bundle.sh <dir> holds opencode-native and the bundled opencode, and no
# other opencode is on PATH. It checks that
#   - both binaries print the same version;
#   - opencode-native starts the bundled server as its background service (`session list`);
#   - a session gets a reply from the mock provider, run on the bundled binary as Bun (`run`);
#   - a TypeScript TUI plugin loads in the TUI on the bundled binary's Bun (JS host), when python3 is there for a pty;
#   - `service stop` stops the service.
# $RUN prefixes each start of a binary (`arch -x86_64` for x86_64 macOS). Needs bash and python3 (the JSON checks, and
# a pty for the TUI step); the state lives in a temporary HOME.
set -euo pipefail
dir=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
mock_script=$here/../bench/mock-provider.ts
run=${RUN:-}
native=$dir/opencode-native
ts=$dir/opencode

fail() { echo "smoke: $*" >&2; exit 1; }

if found=$(command -v opencode); then fail "an opencode is on PATH ($found); the smoke needs a box without one"; fi

work=$(mktemp -d)
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config XDG_DATA_HOME=$work/home/.local/share \
  XDG_STATE_HOME=$work/home/.local/state XDG_CACHE_HOME=$work/home/.cache
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$work/project"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    find "$HOME" -name '*.log' -exec sh -c 'echo "== $1"; tail -n 80 "$1"' _ {} \; >&2 || true
  fi
  [ -n "${mock:-}" ] && kill "$mock" 2>/dev/null
  $run "$native" service stop >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

native_version=$($run "$native" --version | awk '{print $NF}')
ts_version=$($run "$ts" --version | awk '{print $NF}')
echo "opencode-native $native_version, bundled opencode $ts_version"
[ "${native_version#v}" = "${ts_version#v}" ] || fail "the versions differ"
bun=$(BUN_BE_BUN=1 $run "$ts" --version)
echo "bundled Bun $bun"

# The mock provider, run by the bundled binary as Bun: it prints its URL first.
BUN_BE_BUN=1 $run "$ts" "$mock_script" 0 8 0 > "$work/mock.out" 2>&1 &
mock=$!
for _ in $(seq 200); do grep -q '"url"' "$work/mock.out" 2>/dev/null && break; sleep 0.05; done
url=$(sed -nE 's/.*"url":"([^"]+)".*/\1/p' "$work/mock.out" | head -n 1)
[ -n "$url" ] || fail "the mock provider printed no URL: $(cat "$work/mock.out")"
export OPENCODE_CONFIG_CONTENT="{\"model\":\"mock/mock-model\",\"update\":\"disable\",\"share\":\"disabled\",\"snapshots\":false,\"providers\":{\"mock\":{\"name\":\"Mock\",\"package\":\"@ai-sdk/openai-compatible\",\"settings\":{\"baseURL\":\"$url/v1\",\"apiKey\":\"mock\"},\"models\":{\"mock-model\":{\"name\":\"Mock Model\",\"capabilities\":{\"tools\":false},\"limit\":{\"context\":200000,\"output\":8192}}}}}}"
export OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_AUTOUPDATE=1
cd "$work/project"

bounded() { # bounded <seconds> <cmd...>: the command, killed when it outlives the bound.
  local seconds=$1
  shift
  "$@" &
  local pid=$!
  ( sleep "$seconds"; kill "$pid" 2>/dev/null ) &
  local guard=$!
  local status=0
  wait "$pid" || status=$?
  kill "$guard" 2>/dev/null || true
  return "$status"
}

# The background service, started from the bundled binary: JSON, so an empty list still proves it answered.
bounded 180 $run "$native" session list --format json > "$work/sessions.json" || fail "session list failed"
python3 -I -c 'import json, sys; assert isinstance(json.load(open(sys.argv[1])), list)' "$work/sessions.json" ||
  fail "session list printed no JSON list: $(cat "$work/sessions.json")"
registration=$(ls "$XDG_STATE_HOME"/opencode/service*.json)
echo "service registered: $registration"

# A session against the mock provider, through that service.
bounded 180 $run "$native" run "Say hello" > "$work/run.out" 2>&1 || fail "run failed: $(cat "$work/run.out")"
grep -q "quick brown fox" "$work/run.out" || fail "run printed no reply: $(cat "$work/run.out")"
bounded 60 $run "$native" session list --format json > "$work/sessions.json"
python3 -I -c 'import json, sys; assert len(json.load(open(sys.argv[1]))) >= 1' "$work/sessions.json" ||
  fail "the session is not listed: $(cat "$work/sessions.json")"
echo "a session got the mock reply"

# A TypeScript TUI plugin, on the JS host, whose setup writes a marker.
mkdir -p "$XDG_CONFIG_HOME/opencode/plugins/smoke"
cat > "$XDG_CONFIG_HOME/opencode/plugins/smoke/tui.ts" <<'EOF'
import { writeFileSync } from "node:fs"
import { join } from "node:path"

export default {
  id: "smoke.bundle",
  setup() {
    writeFileSync(join(process.env.HOME ?? "", "plugin-loaded"), String(process.versions.bun))
  },
}
EOF
if command -v python3 >/dev/null; then
  TERM=xterm-256color python3 -I "$here/pty.py" 60 "$HOME/plugin-loaded" $run "$native" ||
    fail "the TypeScript plugin did not load"
  echo "the TypeScript plugin loaded on Bun $(cat "$HOME/plugin-loaded")"
  log=$(grep -rh "the JS host runs on" "$XDG_DATA_HOME/opencode/log" 2>/dev/null | tail -n 1 || true)
  echo "log: ${log:-none}"
  real=$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$ts")
  case $log in *"$real"*"opencode's Bun"*) ;; *) fail "the JS host did not run on the bundled binary ($real)" ;; esac
else
  echo "no python3: the TUI plugin step is skipped"
fi

bounded 60 $run "$native" service stop || fail "service stop failed"
sleep 1
if ls "$XDG_STATE_HOME"/opencode/service*.json >/dev/null 2>&1; then fail "a registration is left after service stop"; fi
echo "smoke: ok"
