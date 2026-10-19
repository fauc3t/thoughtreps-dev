#!/usr/bin/env bash
# Two-simulator sync integration run against the local sync server (no AWS).
#
#   scripts/sync-integ.sh                  every scenario
#   scripts/sync-integ.sh testName ...     only these (method names in ThoughtRepsUITests/SyncScenarioTests.swift)
#
# Needs Xcode, Java and pnpm (the server runs on DynamoDB Local), and a checkout of thoughtreps-aws with its dependencies
# installed (`pnpm install --frozen-lockfile` there). The checkout is THOUGHTREPS_AWS_DIR, default ../thoughtreps-aws
# beside this repo (from a git worktree, beside the main checkout). Nothing in that repo is modified.
#
# What it does:
#   - Starts `pnpm --filter infra sync:local` itself unless something already answers on the port (that one is reused
#     and left running), waits for it, and stops what it started on exit.
#   - Uses two simulators of its own, "TR Sync A" (iPhone) and "TR Sync B" (iPad), created if missing and booted if
#     needed. It never touches other simulators, and only shuts down the ones it booted.
#   - Builds once (`build-for-testing`, own derived data), then per scenario gives both devices a fresh random vault and
#     key, removes the app from both, and runs the scenario's XCUITest on both simulators at the same time.
#   - Prints PASS or FAIL per scenario and exits non-zero if any failed. Logs and .xcresult bundles are saved in a run
#     directory (printed first).
#
# Coordination: each scenario is one test method in `SyncScenarioTests`, run on both devices with a role (A asserts what
# the user sees, B does the other side's work). The two test runners hand steps to each other through empty marker files
# in a per-scenario directory on the host (TR_SYNC_DIR), which both simulators can read and write because simulators share
# the Mac's filesystem. A device syncs by sending the app to the background and back and checks in a loop, so no step
# depends on a long sleep. The script passes everything through TEST_RUNNER_-prefixed variables; the app itself gets the
# THOUGHTREPS_SYNC_* variables from the test's launch environment.
#
# A scenario passes only if both tests pass and scripts/sync-pass-check.py finds the two status snapshots in the same end
# state (empty outbox, nothing parked or held, equal thought counts and content digests).
#
# To add a scenario: add a test method to SyncScenarioTests.swift and its name to SCENARIOS below.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${SYNC_LOCAL_PORT:-8787}"
SECRET="${SYNC_LOCAL_SECRET:-dev-secret}"
API_URL="http://127.0.0.1:${PORT}/api/v1"
SCENARIO_TIMEOUT="${SYNC_INTEG_TIMEOUT:-420}"
PHONE_TYPE="${TR_SYNC_PHONE_TYPE:-iPhone 18 Pro}"
PAD_TYPE="${TR_SYNC_PAD_TYPE:-iPad Pro 13-inch (M5)}"
NAME_A="TR Sync A"
NAME_B="TR Sync B"

SCENARIOS=(
  testDeletedWhileOpen_detail
  testDeletedWhileOpen_editor
  testDeletedWhileOpen_coveredByLinkedThought
  testD1_content
  testD2_stateAndSchedule
  testD3_imagesAndFiles
  testD4_links
  testD5_cleanMerge
  testD5_overlappingEdit
  testD5_editAfterDeleteKeepsTheThought
  testD5_deleteAfterEditRemovesTheThought
  testD6_volume
)
if [ "$#" -gt 0 ]; then SCENARIOS=("$@"); fi

# The data scenarios have many steps and the volume scenario moves 500 thoughts; the deleted-while-open ones fit the default.
scenario_timeout() {
  case "$1" in
    testD6_volume) echo "$((SCENARIO_TIMEOUT * 4))" ;;
    testD*) echo "$((SCENARIO_TIMEOUT * 2))" ;;
    *) echo "$SCENARIO_TIMEOUT" ;;
  esac
}

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}/thoughtreps-sync-integ"
RUN_DIR="${TMP_BASE}/run-$(date +%Y%m%d-%H%M%S)"
DERIVED="${TR_SYNC_DERIVED_DATA:-${TMP_BASE}/dd-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)}"
mkdir -p "$RUN_DIR"
echo "Run directory: $RUN_DIR"

SERVER_PID=""
BOOTED=()
CHILDREN=()

cleanup() {
  local pid
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
  if [ -n "$SERVER_PID" ]; then
    kill -- "-$SERVER_PID" 2>/dev/null
    echo "Stopped the local server this run started."
  fi
  local udid
  for udid in ${BOOTED[@]+"${BOOTED[@]}"}; do xcrun simctl shutdown "$udid" 2>/dev/null; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

die() { echo "ERROR: $*" >&2; exit 2; }

# MARK: Server

# An unauthenticated GET /head gets the sync server's JSON 401 with a serverTime; anything else on the port isn't it.
server_answers() {
  curl -s --max-time 2 "${API_URL}/head" 2>/dev/null | grep -q '"serverTime"'
}

port_in_use() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

resolve_aws_dir() {
  local candidate main
  if [ -n "${THOUGHTREPS_AWS_DIR:-}" ]; then echo "$THOUGHTREPS_AWS_DIR"; return; fi
  candidate="$ROOT/../thoughtreps-aws"
  if [ ! -d "$candidate" ]; then
    main="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    [ -n "$main" ] && candidate="$main/../thoughtreps-aws"
  fi
  echo "$candidate"
}

start_server() {
  if server_answers; then
    echo "Reusing the server already answering on port $PORT (secret taken from SYNC_LOCAL_SECRET, default dev-secret)."
    return
  fi
  ! port_in_use || die "Port $PORT is in use by something that isn't the sync server (set SYNC_LOCAL_PORT)."
  local aws_dir
  aws_dir="$(resolve_aws_dir)"
  [ -d "$aws_dir/infra" ] || die "No thoughtreps-aws checkout at $aws_dir (set THOUGHTREPS_AWS_DIR)."
  command -v java >/dev/null || die "Java is required for the local server (DynamoDB Local)."
  command -v pnpm >/dev/null || die "pnpm is required for the local server."
  [ -d "$aws_dir/node_modules" ] || die "Run 'pnpm install --frozen-lockfile' in $aws_dir first."
  echo "Starting the local sync server from $aws_dir on port $PORT..."
  (
    cd "$aws_dir" || exit 1
    SYNC_LOCAL_SECRET="$SECRET" SYNC_LOCAL_PORT="$PORT" \
      exec python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      pnpm --filter infra sync:local
  ) >"$RUN_DIR/server.log" 2>&1 &
  SERVER_PID=$!
  local waited=0
  until server_answers; do
    kill -0 "$SERVER_PID" 2>/dev/null || { tail -20 "$RUN_DIR/server.log"; die "The local server exited early (see $RUN_DIR/server.log)."; }
    [ "$waited" -ge 120 ] && { tail -20 "$RUN_DIR/server.log"; die "The local server didn't come up in 120 s."; }
    sleep 1
    waited=$((waited + 1))
  done
  echo "Server is up (${waited} s)."
}

# MARK: Simulators

simctl_json() { xcrun simctl list "$@" -j; }

latest_runtime() {
  simctl_json runtimes | python3 -I -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")'
}

device_type_id() {
  simctl_json devicetypes | NAME="$1" python3 -I -c '
import json, os, sys
for t in json.load(sys.stdin)["devicetypes"]:
    if t["name"] == os.environ["NAME"]:
        print(t["identifier"]); break'
}

# Prints the UDID of the simulator named $1, creating it from device type $2 if there is none.
ensure_simulator() {
  local name="$1" type_name="$2" udid type runtime
  udid="$(simctl_json devices | NAME="$name" python3 -I -c '
import json, os, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == os.environ["NAME"] and d.get("isAvailable", True):
            print(d["udid"]); sys.exit()')"
  if [ -z "$udid" ]; then
    type="$(device_type_id "$type_name")"
    [ -n "$type" ] || die "No device type named '$type_name' (xcrun simctl list devicetypes)."
    runtime="$(latest_runtime)"
    [ -n "$runtime" ] || die "No iOS simulator runtime is installed."
    udid="$(xcrun simctl create "$name" "$type" "$runtime")" || die "Couldn't create the simulator '$name'."
    echo "Created simulator '$name' ($udid)." >&2
  fi
  echo "$udid"
}

simctl_state() {
  simctl_json devices | UDID="$1" python3 -I -c '
import json, os, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["udid"] == os.environ["UDID"]:
            print(d["state"])'
}

boot_simulator() {
  local udid="$1" state
  state="$(simctl_state "$udid")"
  local waited=0
  while [ "$state" = "Shutting Down" ] && [ "$waited" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
    state="$(simctl_state "$udid")"
  done
  if [ "$state" = "Shutdown" ]; then
    xcrun simctl boot "$udid" || die "Couldn't boot simulator $udid."
    BOOTED+=("$udid")
  elif [ "$state" != "Booted" ] && [ "$state" != "Booting" ]; then
    die "Simulator $udid is in state '$state'."
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || die "Simulator $udid didn't finish booting."
}

# MARK: Build

build() {
  echo "Building for testing (derived data: $DERIVED)..."
  (cd "$ROOT" && xcodegen >"$RUN_DIR/xcodegen.log" 2>&1) || die "xcodegen failed (see $RUN_DIR/xcodegen.log)."
  (cd "$ROOT" && xcodebuild build-for-testing -scheme ThoughtRepsSyncIntegration \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" >"$RUN_DIR/build.log" 2>&1) \
    || { tail -30 "$RUN_DIR/build.log"; die "Build failed (see $RUN_DIR/build.log)."; }
  local runs
  runs="$(ls "$DERIVED"/Build/Products/ThoughtRepsSyncIntegration_*.xctestrun 2>/dev/null)"
  [ -n "$runs" ] && [ "$(printf '%s\n' "$runs" | wc -l)" -eq 1 ] \
    || die "Expected exactly one ThoughtRepsSyncIntegration .xctestrun in $DERIVED/Build/Products."
  XCTESTRUN="$runs"
  APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DERIVED"/Build/Products/Debug-iphonesimulator/ThoughtReps.app/Info.plist)"
}

# MARK: Scenarios

run_device() {
  local role="$1" udid="$2" scenario="$3" dir="$4" vault="$5" key="$6"
  TEST_RUNNER_TR_SYNC_ROLE="$role" TEST_RUNNER_TR_SYNC_DIR="$dir/signals" TEST_RUNNER_TR_SYNC_URL="$API_URL" \
    TEST_RUNNER_TR_SYNC_VAULT="$vault" TEST_RUNNER_TR_SYNC_SECRET="$SECRET" TEST_RUNNER_TR_SYNC_KEY="$key" \
    exec xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "platform=iOS Simulator,id=$udid" \
    -only-testing:"ThoughtRepsUITests/SyncScenarioTests/$scenario" -parallel-testing-enabled NO -collect-test-diagnostics never \
    -resultBundlePath "$dir/device-$role.xcresult" >"$dir/device-$role.log" 2>&1
}

# A skipped test also exits 0, so a pass needs the test's own "passed" line.
passed_in_log() {
  grep -Eq "Test [Cc]ase '.*SyncScenarioTests.*$2.*' passed" "$1"
}

run_scenario() {
  local scenario="$1" dir="$RUN_DIR/$1" vault key elapsed=0 limit
  limit="$(scenario_timeout "$scenario")"
  mkdir -p "$dir/signals"
  vault="itest$(openssl rand -hex 6)"
  key="$(openssl rand -base64 32)"
  xcrun simctl uninstall "$UDID_A" "$APP_BUNDLE_ID" >/dev/null 2>&1
  xcrun simctl uninstall "$UDID_B" "$APP_BUNDLE_ID" >/dev/null 2>&1
  echo "--- $scenario (vault $vault)"
  run_device a "$UDID_A" "$scenario" "$dir" "$vault" "$key" &
  local pid_a=$!
  run_device b "$UDID_B" "$scenario" "$dir" "$vault" "$key" &
  local pid_b=$!
  CHILDREN=("$pid_a" "$pid_b")
  while kill -0 "$pid_a" 2>/dev/null || kill -0 "$pid_b" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
      echo "Timed out after ${limit} s; stopping this scenario's test runs."
      kill "$pid_a" "$pid_b" 2>/dev/null
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  local status_a=1 status_b=1
  wait "$pid_a" 2>/dev/null && status_a=0
  wait "$pid_b" 2>/dev/null && status_b=0
  if [ "$status_a" -eq 0 ] && [ "$status_b" -eq 0 ] \
     && passed_in_log "$dir/device-a.log" "$scenario" && passed_in_log "$dir/device-b.log" "$scenario"; then
    local mismatch
    if mismatch="$(python3 -I "$ROOT/scripts/sync-pass-check.py" "$dir/signals/status-a.json" "$dir/signals/status-b.json")"; then
      echo "PASS $scenario (${elapsed} s)"
      return 0
    fi
    echo "FAIL $scenario (the tests passed, but the devices did not end in the same state)"
    printf '%s\n' "$mismatch" | sed 's/^/    /'
    echo "  logs: $dir"
    return 1
  fi
  echo "FAIL $scenario (device A exit $status_a, device B exit $status_b)"
  local role
  for role in a b; do
    echo "  device $role failures:"
    grep -E "error:|failed|Test Case .* (failed|skipped)" "$dir/device-$role.log" | head -8 | sed 's/^/    /'
  done
  echo "  logs: $dir"
  return 1
}

start_server
build
UDID_A="$(ensure_simulator "$NAME_A" "$PHONE_TYPE")" || exit 2
UDID_B="$(ensure_simulator "$NAME_B" "$PAD_TYPE")" || exit 2
boot_simulator "$UDID_A"
boot_simulator "$UDID_B"
echo "Simulators: $NAME_A $UDID_A, $NAME_B $UDID_B"

FAILED=0
for scenario in "${SCENARIOS[@]}"; do
  run_scenario "$scenario" || FAILED=$((FAILED + 1))
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: ${#SCENARIOS[@]} scenario(s). Logs: $RUN_DIR"
else
  echo "FAIL: $FAILED of ${#SCENARIOS[@]} scenario(s) failed. Logs: $RUN_DIR"
  [ -n "$SERVER_PID" ] && { echo "Server log tail:"; tail -15 "$RUN_DIR/server.log" | sed 's/^/  /'; }
  exit 1
fi
