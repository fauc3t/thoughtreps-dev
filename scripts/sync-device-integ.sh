#!/usr/bin/env bash
# Two-device sync integration run on a real iPhone and a real iPad against the AWS dev sync stack (dev-secret auth).
#
#   scripts/sync-device-integ.sh                  every scenario
#   scripts/sync-device-integ.sh testName ...     only these (method names in ThoughtRepsUITests/SyncScenarioTests.swift)
#
# Needs Xcode, xcodegen, a paired and unlocked iPhone and iPad with Developer Mode on, both on the same network as this Mac
# (the test runners reach the coordinator at the Mac's LAN address), `Config/Local.xcconfig` for signing, and AWS access to the
# dev account (profile thoughtreps-dev) to read the dev secret. Devices default to the only connected, paired physical iPhone
# (A) and iPad (B); otherwise set TR_DEVICE_A and TR_DEVICE_B to UDIDs from `xcrun devicectl list devices`. TR_SYNC_DEV_SECRET
# replaces the SSM lookup. Before touching the devices it prints their names and UDIDs and asks you to type `wipe`, because
# the run deletes Thought Reps and all its data (thoughts, sync key) from both; TR_DEVICE_WIPE_OK=1 skips the prompt. Design: designs/Thought Reps — Device Sync Harness Spec.md.
#
# What it does, like scripts/sync-integ.sh but on devices:
#   - Builds once (`build-for-testing`, own derived data), then per scenario resets both devices, gives them a fresh `test-`
#     vault and random key, runs the scenario's XCUITest on both at once, pulls each app's status snapshot, and cleans up.
#   - Marker files can't cross devices, so the test runners hand steps to each other through scripts/sync-coordinator.py on
#     this Mac's LAN address (TR_SYNC_COORDINATOR, the URL with a random run token). Only the test runners talk to it.
#   - Prints PASS or FAIL per scenario and exits non-zero if any failed or any cleanup failed. Logs, .xcresult bundles and
#     status snapshots are saved in a run directory (printed first).
#
# Nothing a run creates outlives it:
#   - Ledger: every vault is appended to ledger.jsonl in the run directory before it is used, and again once it is erased on
#     the server (POST /dev/vaults/<id>/erase, which clears its records and blobs; 404 means there was nothing to erase).
#   - Exit trap: on any exit (pass, fail, Ctrl-C) it erases every uncleaned ledger vault, resets both devices, stops the
#     coordinator and the test runs.
#   - Sweep: the next run's preflight replays the ledgers of earlier runs, and refuses to start if a device still holds a
#     sync key after a reset.
#   - Reset: launches the app with `-TRResetSyncTestState <nonce>` (DEBUG: forgets the Keychain vault key, the sync App Attest
#     key id and sync.sqlite, and removes an iCloud Keychain copy only if it is a test vault's; no network), pulls the result
#     file to confirm no key is left, then uninstalls the app. The Keychain item survives an uninstall, hence the reset first.
#   - The tests launch with "Save sync key to iCloud Keychain" off, so no test key reaches the tester's iCloud.
#   - Run directories older than 7 days are deleted at start.
#
# A scenario passes only if both tests pass and scripts/sync-pass-check.py finds the two status snapshots in the same end
# state (empty outbox, nothing parked or held, equal thought counts and content digests).
#
# To add a scenario: add a test method to SyncScenarioTests.swift and its name to SCENARIOS below.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENARIO_TIMEOUT="${SYNC_INTEG_TIMEOUT:-600}"
DEV_URL_DEFAULT="$(grep -o 'https://[^"]*' "$ROOT/ThoughtReps/Sync/SyncAccountService.swift" | head -1)"
API_URL="${TR_SYNC_DEV_URL:-$DEV_URL_DEFAULT}"
SSM_PROFILE="${TR_SYNC_AWS_PROFILE:-thoughtreps-dev}"
SSM_NAME="/thoughtreps/dev/sync/dev-bypass-secret"

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
TMP_BASE="${TMP_BASE%/}/thoughtreps-sync-device-integ"
RUN_DIR="${TMP_BASE}/run-$(date +%Y%m%d-%H%M%S)"
DERIVED="${TR_SYNC_DERIVED_DATA:-${TMP_BASE}/dd-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)}"
LEDGER="$RUN_DIR/ledger.jsonl"
AUTH_HEADER="$RUN_DIR/.auth-header"
mkdir -p "$RUN_DIR"
touch "$LEDGER"
echo "Run directory: $RUN_DIR"

SECRET=""
UDID_A=""
UDID_B=""
APP_BUNDLE_ID=""
APP_PATH=""
XCTESTRUN=""
COORD_PID=""
COORD_URL=""
RUN_KEYS=()
DEVICES_TOUCHED=0
CHILDREN=()

die() { echo "ERROR: $*" >&2; exit 2; }

# MARK: Cleanup

# Prints the vaults a ledger created and never marked cleaned; exits non-zero on a malformed line. Callers must read the
# output with `x="$(uncleaned_in ...)" || ...`, since a pipe or process substitution hides the exit status.
uncleaned_in() {
  python3 -I -c '
import json, sys
state = {}
n = 0
try:
    for n, line in enumerate(open(sys.argv[1]), 1):
        line = line.strip()
        if line:
            entry = json.loads(line)
            state[entry["vault"]] = entry["state"]
except (OSError, ValueError, KeyError, TypeError) as e:
    sys.exit("Malformed ledger %s (line %d): %s" % (sys.argv[1], n, e))
print("\n".join(v for v, s in state.items() if s != "cleaned"))' "$1"
}

ledger_add() { # ledger_add <ledger> <vault> <created|cleaned>
  printf '{"vault":"%s","state":"%s","at":"%s"}\n' "$2" "$3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$1"
}

# Erases a dev-secret vault on the server. A 404 counts only when the body is the server's own {"error":"not_found"} (the vault
# was never created or is already gone); API Gateway's missing-route 404 is {"message":"Not Found"} and is a failure.
erase_vault() {
  local code body="$RUN_DIR/erase-response.json"
  code="$(curl -s -o "$body" -w '%{http_code}' --max-time 30 -X POST -H "@$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d '{}' "${API_URL}/dev/vaults/$1/erase" 2>/dev/null || true)"
  [ "$code" = "200" ] && return 0
  [ "$code" = "404" ] || return 1
  python3 -I -c '
import json, sys
try:
    sys.exit(0 if json.load(open(sys.argv[1])).get("error") == "not_found" else 1)
except Exception:
    sys.exit(1)' "$body"
}

# Erases every uncleaned vault in a ledger and marks them; returns non-zero if any erase failed.
clean_ledger() {
  local ledger="$1" vault failed=0 pending
  pending="$(uncleaned_in "$ledger")" || return 1
  while IFS= read -r vault; do
    [ -n "$vault" ] || continue
    if erase_vault "$vault"; then
      ledger_add "$ledger" "$vault" cleaned
    else
      echo "Couldn't erase vault $vault on the server." >&2
      failed=1
    fi
  done <<<"$pending"
  return "$failed"
}

# Names files in the run directory that contain the dev secret or a vault key; never prints the values.
warn_secrets_at_rest() {
  local found
  [ -n "$SECRET" ] || return 0
  found="$(grep -rlF -f <(printf '%s\n' "$SECRET" ${RUN_KEYS[@]+"${RUN_KEYS[@]}"}) "$RUN_DIR" 2>/dev/null)"
  [ -z "$found" ] || printf 'WARNING: the dev secret or a vault key appears in these files:\n%s\n' "$found" >&2
}

cleanup() {
  local status=$? pid status_reset_failed=0
  trap - EXIT
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
  if [ -n "$SECRET" ] && ! clean_ledger "$LEDGER"; then
    echo "Cleanup incomplete: the next run's preflight will retry from $LEDGER." >&2
    [ "$status" -eq 0 ] && status=1
  fi
  if [ "$DEVICES_TOUCHED" -eq 1 ]; then
    reset_device "$UDID_A" >/dev/null 2>&1 || { echo "Couldn't reset device A; the next run's preflight will check." >&2; status_reset_failed=1; }
    reset_device "$UDID_B" >/dev/null 2>&1 || { echo "Couldn't reset device B; the next run's preflight will check." >&2; status_reset_failed=1; }
    [ "$status_reset_failed" -eq 0 ] || [ "$status" -ne 0 ] || status=1
  fi
  if [ -n "$COORD_PID" ]; then kill "$COORD_PID" 2>/dev/null; fi
  rm -f "$AUTH_HEADER"
  warn_secrets_at_rest
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# MARK: Devices

# Prints "<udid>\t<kind>\t<name>\t<problem>" per connected-or-known physical device; problem is empty when usable.
list_devices() {
  local out="$RUN_DIR/devices.json"
  xcrun devicectl list devices --json-output "$out" >"$RUN_DIR/devices.log" 2>&1 || return 1
  python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, dev, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "simulated" or hw.get("platform") != "iOS":
        continue
    problem = ""
    if conn.get("pairingState") != "paired":
        problem = "not paired"
    elif conn.get("tunnelState") == "unavailable":
        problem = "not connected (unplugged, asleep or off the network)"
    elif dev.get("developerModeStatus") == "disabled":
        problem = "Developer Mode is off"
    print("\t".join([hw.get("udid", ""), hw.get("deviceType", ""), dev.get("name", ""), problem]))' "$out"
}

device_line() { printf '%s\n' "$DEVICE_LIST" | awk -F'\t' -v u="$1" '$1 == u'; }

# Sets UDID_A and UDID_B, from TR_DEVICE_A/B or the only usable physical iPhone and iPad.
choose_devices() {
  DEVICE_LIST="$(list_devices)" || die "xcrun devicectl list devices failed (see $RUN_DIR/devices.log)."
  UDID_A="${TR_DEVICE_A:-}"
  UDID_B="${TR_DEVICE_B:-}"
  local kind want line
  for kind in iPhone iPad; do
    if [ "$kind" = iPhone ]; then want="$UDID_A"; else want="$UDID_B"; fi
    if [ -z "$want" ]; then
      local usable count
      usable="$(printf '%s\n' "$DEVICE_LIST" | awk -F'\t' -v k="$kind" '$2 == k && $4 == ""')"
      count="$(printf '%s' "$usable" | grep -c . || true)"
      if [ "$count" -eq 0 ]; then
        echo "No usable physical $kind. Known physical devices:" >&2
        printf '%s\n' "$DEVICE_LIST" | awk -F'\t' '{ printf "  %s  %s  %s  %s\n", $1, $2, $3, ($4 == "" ? "ok" : $4) }' >&2
        die "Connect and unlock an $kind (or set TR_DEVICE_$([ "$kind" = iPhone ] && echo A || echo B))."
      elif [ "$count" -gt 1 ]; then
        die "More than one usable $kind; set TR_DEVICE_$([ "$kind" = iPhone ] && echo A || echo B) to a UDID from 'xcrun devicectl list devices'."
      fi
      want="$(printf '%s' "$usable" | cut -f1)"
    fi
    line="$(device_line "$want")"
    [ -n "$line" ] || die "Device $want isn't a known physical device (xcrun devicectl list devices)."
    [ -z "$(printf '%s' "$line" | cut -f4)" ] || die "$(printf '%s' "$line" | cut -f3) ($want): $(printf '%s' "$line" | cut -f4)."
    if [ "$kind" = iPhone ]; then UDID_A="$want"; else UDID_B="$want"; fi
  done
  [ "$UDID_A" != "$UDID_B" ] || die "TR_DEVICE_A and TR_DEVICE_B are the same device."
  echo "Devices: A $(printf '%s' "$(device_line "$UDID_A")" | cut -f3) ($UDID_A), B $(printf '%s' "$(device_line "$UDID_B")" | cut -f3) ($UDID_B)"
}

dc() { xcrun devicectl "$@"; }

# Resets one device: installs the app if needed, launches it with the reset argument, checks the result file says no sync key
# is left, then uninstalls it.
reset_device() {
  local udid="$1" nonce result="$RUN_DIR/reset-$1.json" waited=0
  nonce="$(openssl rand -hex 8)"
  rm -f "$result"
  dc device install app --device "$udid" --timeout 120 "$APP_PATH" >>"$RUN_DIR/devicectl.log" 2>&1 \
    || { echo "Couldn't install the app on $udid (see $RUN_DIR/devicectl.log)." >&2; return 1; }
  dc device process launch --device "$udid" --terminate-existing "$APP_BUNDLE_ID" -- -TRResetSyncTestState "$nonce" \
    >>"$RUN_DIR/devicectl.log" 2>&1 \
    || { echo "Couldn't launch the app on $udid; unlock it (see $RUN_DIR/devicectl.log)." >&2; return 1; }
  until reset_confirmed "$udid" "$nonce" "$result"; do
    [ "$waited" -ge 30 ] && { echo "Device $udid never confirmed the reset (see $RUN_DIR/devicectl.log)." >&2; return 1; }
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["keyPresent"])' "$result")" != "False" ]; then
    echo "Device $udid still holds a sync key after the reset." >&2
    return 1
  fi
  dc device uninstall app --device "$udid" --timeout 60 "$APP_BUNDLE_ID" >>"$RUN_DIR/devicectl.log" 2>&1 \
    || { echo "Couldn't uninstall the app from $udid (see $RUN_DIR/devicectl.log)." >&2; return 1; }
}

reset_confirmed() { # reset_confirmed <udid> <nonce> <local file>
  dc device copy from --device "$1" --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
    --source Documents/sync-reset-result.json --destination "$3" --timeout 20 >>"$RUN_DIR/devicectl.log" 2>&1 || return 1
  [ "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("nonce", ""))' "$3" 2>/dev/null)" = "$2" ]
}

# MARK: Preflight

confirm_wipe() {
  [ "${TR_DEVICE_WIPE_OK:-}" = 1 ] && return 0
  {
    echo
    echo "This run will DELETE Thought Reps and all its data (thoughts, sync key) from:"
    echo "  A: $(printf '%s' "$(device_line "$UDID_A")" | cut -f3)  ($UDID_A)"
    echo "  B: $(printf '%s' "$(device_line "$UDID_B")" | cut -f3)  ($UDID_B)"
  } >&2
  local answer=""
  { printf 'Type "wipe" to continue: ' >/dev/tty; } 2>/dev/null || die "No terminal to confirm on; set TR_DEVICE_WIPE_OK=1 to skip the prompt."
  read -r answer </dev/tty 2>/dev/null || answer=""
  [ "$answer" = wipe ] || die "Aborted: nothing was changed."
}

lan_ip() {
  local ip
  for iface in en0 en1; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [ -n "$ip" ] && { echo "$ip"; return; }
  done
}

fetch_secret() {
  if [ -n "${TR_SYNC_DEV_SECRET:-}" ]; then
    SECRET="$TR_SYNC_DEV_SECRET"
  else
    command -v aws >/dev/null || die "aws CLI not found; install it or set TR_SYNC_DEV_SECRET."
    SECRET="$(aws ssm get-parameter --profile "$SSM_PROFILE" --with-decryption --name "$SSM_NAME" \
      --query Parameter.Value --output text 2>"$RUN_DIR/ssm.log")" \
      || die "Couldn't read the dev secret from SSM with profile $SSM_PROFILE (see $RUN_DIR/ssm.log; try 'aws sso login --profile $SSM_PROFILE')."
    [ -n "$SECRET" ] && [ "$SECRET" != "None" ] || die "The SSM parameter $SSM_NAME is empty."
  fi
  (umask 077; printf 'Authorization: Dev %s\n' "$SECRET" >"$AUTH_HEADER")
}

# Erases vaults that earlier runs created and never cleaned, then deletes run directories older than 7 days.
sweep() {
  local ledger vault swept=0 pending
  for ledger in "$TMP_BASE"/run-*/ledger.jsonl; do
    [ -f "$ledger" ] && [ "$ledger" != "$LEDGER" ] || continue
    pending="$(uncleaned_in "$ledger")" || die "Can't read $ledger; fix or delete that run directory and rerun."
    while IFS= read -r vault; do
      [ -n "$vault" ] || continue
      echo "Sweeping vault $vault left by an earlier run ($(dirname "$ledger"))."
      erase_vault "$vault" || die "Couldn't erase leftover vault $vault; fix the dev stack access and rerun."
      ledger_add "$ledger" "$vault" cleaned
      swept=$((swept + 1))
    done <<<"$pending"
  done
  [ "$swept" -eq 0 ] || echo "Swept $swept leftover vault(s)."
  find "$TMP_BASE" -maxdepth 1 -type d -name 'run-*' -mtime +7 -exec rm -rf {} + 2>/dev/null
  return 0
}

start_coordinator() {
  local ip token waited=0
  ip="$(lan_ip)"
  [ -n "$ip" ] || die "No LAN address on en0 or en1; connect this Mac to the network the devices are on."
  token="$(openssl rand -hex 12)"
  python3 -I "$ROOT/scripts/sync-coordinator.py" "$ip" "$token" >"$RUN_DIR/coordinator.log" 2>&1 &
  COORD_PID=$!
  until grep -q '^URL ' "$RUN_DIR/coordinator.log" 2>/dev/null; do
    kill -0 "$COORD_PID" 2>/dev/null || { cat "$RUN_DIR/coordinator.log"; die "The coordinator exited early."; }
    [ "$waited" -ge 10 ] && die "The coordinator didn't start."
    sleep 1
    waited=$((waited + 1))
  done
  COORD_URL="$(sed -n 's/^URL //p' "$RUN_DIR/coordinator.log" | head -1)"
  echo "Coordinator: ${COORD_URL%/*}/<run token>"
}

# MARK: Build

build() {
  [ -f "$ROOT/Config/Local.xcconfig" ] || die "Config/Local.xcconfig is missing (copy Config/Local.xcconfig.example and set your team)."
  echo "Building for testing (derived data: $DERIVED)..."
  (cd "$ROOT" && xcodegen >"$RUN_DIR/xcodegen.log" 2>&1) || die "xcodegen failed (see $RUN_DIR/xcodegen.log)."
  (cd "$ROOT" && xcodebuild build-for-testing -scheme ThoughtRepsSyncIntegration -allowProvisioningUpdates \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" >"$RUN_DIR/build.log" 2>&1) \
    || { tail -30 "$RUN_DIR/build.log"; die "Build failed (see $RUN_DIR/build.log)."; }
  local runs
  runs="$(ls "$DERIVED"/Build/Products/ThoughtRepsSyncIntegration_*.xctestrun 2>/dev/null)"
  [ -n "$runs" ] && [ "$(printf '%s\n' "$runs" | wc -l)" -eq 1 ] \
    || die "Expected exactly one ThoughtRepsSyncIntegration .xctestrun in $DERIVED/Build/Products."
  XCTESTRUN="$runs"
  APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/ThoughtReps.app"
  APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
}

# MARK: Scenarios

run_device() {
  local role="$1" udid="$2" scenario="$3" dir="$4" vault="$5" key="$6"
  TEST_RUNNER_TR_SYNC_ROLE="$role" TEST_RUNNER_TR_SYNC_COORDINATOR="$COORD_URL" TEST_RUNNER_TR_SYNC_URL="$API_URL" \
    TEST_RUNNER_TR_SYNC_VAULT="$vault" TEST_RUNNER_TR_SYNC_SECRET="$SECRET" TEST_RUNNER_TR_SYNC_KEY="$key" \
    exec xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$udid" \
    -only-testing:"ThoughtRepsUITests/SyncScenarioTests/$scenario" -parallel-testing-enabled NO \
    -resultBundlePath "$dir/device-$role.xcresult" >"$dir/device-$role.log" 2>&1
}

# A skipped test also exits 0, so a pass needs the test's own "passed" line.
passed_in_log() {
  grep -Eq "Test [Cc]ase '.*SyncScenarioTests.*$2.*' passed" "$1"
}

pull_status() { # pull_status <udid> <role> <dir>
  dc device copy from --device "$1" --domain-type appDataContainer --domain-identifier "$APP_BUNDLE_ID" \
    --source "Documents/status-$2.json" --destination "$3/status-$2.json" --timeout 30 >>"$RUN_DIR/devicectl.log" 2>&1 \
    || echo "  (no status snapshot from device $2)"
}

run_scenario() {
  local scenario="$1" dir="$RUN_DIR/$1" vault key elapsed=0 limit
  limit="$(scenario_timeout "$scenario")"
  mkdir -p "$dir"
  vault="test-$(openssl rand -hex 6)"
  key="$(openssl rand -base64 32)"
  RUN_KEYS+=("$key")
  ledger_add "$LEDGER" "$vault" created
  echo "--- $scenario (vault $vault)"
  DEVICES_TOUCHED=1
  if ! reset_device "$UDID_A" || ! reset_device "$UDID_B"; then
    echo "FAIL $scenario (couldn't reset the devices)"
    clean_ledger "$LEDGER"
    return 1
  fi
  curl -s -o /dev/null --max-time 5 -X DELETE "$COORD_URL"
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
  CHILDREN=()
  pull_status "$UDID_A" a "$dir"
  pull_status "$UDID_B" b "$dir"
  if ! clean_ledger "$LEDGER"; then
    echo "FAIL $scenario (the vault $vault couldn't be erased)"
    return 1
  fi
  if [ "$status_a" -eq 0 ] && [ "$status_b" -eq 0 ] \
     && passed_in_log "$dir/device-a.log" "$scenario" && passed_in_log "$dir/device-b.log" "$scenario"; then
    local mismatch
    if mismatch="$(python3 -I "$ROOT/scripts/sync-pass-check.py" "$dir/status-a.json" "$dir/status-b.json")"; then
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

choose_devices
confirm_wipe
[ -n "$API_URL" ] || die "No dev API URL (set TR_SYNC_DEV_URL)."
fetch_secret
start_coordinator
sweep
build
echo "Resetting both devices (preflight)..."
DEVICES_TOUCHED=1
reset_device "$UDID_A" || die "Preflight reset of device A failed."
reset_device "$UDID_B" || die "Preflight reset of device B failed."

FAILED=0
for scenario in "${SCENARIOS[@]}"; do
  run_scenario "$scenario" || FAILED=$((FAILED + 1))
done

clean_ledger "$LEDGER" || FAILED=$((FAILED + 1))
if ! LEFT="$(uncleaned_in "$LEDGER")"; then
  FAILED=$((FAILED + 1))
elif [ -n "$LEFT" ]; then
  echo "FAIL: cleanup left vault(s) on the server: $(printf '%s' "$LEFT" | tr '\n' ' ')"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: ${#SCENARIOS[@]} scenario(s), every ledger entry cleaned. Logs: $RUN_DIR"
else
  echo "FAIL: $FAILED problem(s) in ${#SCENARIOS[@]} scenario(s) or cleanup. Logs: $RUN_DIR"
  exit 1
fi
