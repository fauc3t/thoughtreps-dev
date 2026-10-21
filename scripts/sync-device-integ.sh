#!/usr/bin/env bash
# Two-device sync integration run on a real iPhone and a real iPad against the AWS dev sync stack (dev-secret auth).
#
#   scripts/sync-device-integ.sh                  the data scenarios (D1 to D6 and the deleted-while-open ones), same as `data`
#   scripts/sync-device-integ.sh data             the same
#   scripts/sync-device-integ.sh testName ...     only these data scenarios (method names in ThoughtRepsUITests/SyncScenarioTests.swift)
#   scripts/sync-device-integ.sh account          the account scenarios A1 to A6 (ThoughtRepsUITests/SyncAccountScenarioTests.swift)
#   scripts/sync-device-integ.sh account --through A3    A1 to A3, then clean up (for debugging)
# `account` can't be combined with `data` or with scenario names. See "Account mode" below.
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
#   - Secrets: XCUITest logs the app's launch environment (.xcresult Diagnostics), so redact_secrets overwrites the dev secret
#     and the run's vault keys in every run-directory file with same-length `*` after each scenario and on exit; the run fails
#     if any remain (file names only). The Authorization header file lives outside the run directory, private, removed on exit.
#
# A scenario passes only if both tests pass and scripts/sync-pass-check.py finds the two status snapshots in the same end
# state (empty outbox, nothing parked or held, equal thought counts and content digests).
#
# To add a scenario: add a test method to SyncScenarioTests.swift and its name to SCENARIOS below.
#
# Account mode (`account`): the app signs in for real instead of using a dev vault, so the data run's per-scenario `test-` vault,
# dev secret and key aren't passed to the app. Preflight sweeps and resets both devices as above, then the A scenarios run in order
# on both devices at once, in two legs because A5 needs a reinstall:
#   - leg 1: A1 to A4 in one xcodebuild per device (A1 creates the vault with Sign in with Apple; B only ever joins). The state
#     carries from one method to the next, so the first failure stops the chain.
#   - between the legs: the app is uninstalled and installed again on B only, without the reset launch, so its Keychain vault key
#     survives and the app asks to resume.
#   - leg 2: A5 (reinstall and resume; it skips, with B rejoining by recovery code, if the Keychain item didn't survive) and A6
#     (Delete sync data; both devices end signed out and keep their thoughts).
# Sign in with Apple needs a tap on device A: the test tells the script (marker `action-siwa-a`) and the script prints
# `ACTION: approve Sign in with Apple on <device A>` each time. A6 may ask a second time.
#   - The vault the account creates (marker `account-vault`) goes into the ledger with `"account":true`. Cleaning it calls the
#     dev-only `POST /dev/vaults/<id>/delete-account` (deletes the account that owns the vault; 200 or 404), then the erase as
#     above. After A6 passed, delete-account must answer 404: a 200 means A6 didn't really delete, and the run fails.
#   - Invites and recovery codes (markers `invite*` and `recovery*`) are secrets: the coordinator also writes them to a private
#     file outside the run directory (removed on exit) and they are redacted from the run directory like the dev secret.
#   - The pass check compares the status snapshots at the end of leg 1 (after A4, both devices in the vault) and of leg 2 only
#     when it ends at A5; after A6 both devices are signed out and the tests' own convergence checks are the evidence.

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
ACCOUNT_SCENARIOS=(
  testA1_createAndInviteJoinMerge
  testA2_recoveryCodeJoinErase
  testA3_devices
  testA4_leaveAndEraseAndLeave
  testA5_reinstallResume
  testA6_deleteSyncData
)

# MODE is data (SCENARIOS, all of them unless named) or account (ACCOUNT_SCENARIOS up to THROUGH, a number 1 to 6).
usage_error() { echo "ERROR: $*" >&2; echo "Usage: $0 [data | testName ...] | account [--through A1..A6]" >&2; exit 2; }
parse_args() {
  local named=() saw_data=0 saw_account=0 through="" arg scenario
  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      data) saw_data=1 ;;
      account) saw_account=1 ;;
      --through)
        [ "$#" -gt 0 ] || usage_error "--through needs a scenario (A1 to A6)."
        through="$1"
        shift
        ;;
      --through=*) through="${arg#--through=}" ;;
      -*) usage_error "Unknown option $arg." ;;
      *) named+=("$arg") ;;
    esac
  done
  if [ "$saw_account" -eq 1 ]; then
    [ "$saw_data" -eq 0 ] && [ "${#named[@]}" -eq 0 ] \
      || usage_error "An account run can't be combined with data scenarios; run them separately."
    MODE=account
    THROUGH=6
    if [ -n "$through" ]; then
      case "$through" in
        [Aa][1-6]) THROUGH="${through#?}" ;;
        *) usage_error "--through takes A1 to A6, not '$through'." ;;
      esac
    fi
  else
    [ -z "$through" ] || usage_error "--through only applies to an account run."
    MODE=data
    if [ "${#named[@]}" -gt 0 ]; then
      local name known
      for name in "${named[@]}"; do
        case "$name" in testA[0-9]*) usage_error "$name is an account scenario; run it with 'account' (see --through)." ;; esac
        known=0
        for scenario in "${SCENARIOS[@]}"; do [ "$scenario" != "$name" ] || known=1; done
        [ "$known" -eq 1 ] || usage_error "$name isn't a data scenario (see SCENARIOS in this script)."
      done
      SCENARIOS=("${named[@]}")
    fi
  fi
}
MODE=data
THROUGH=6
parse_args "$@"
if [ "$MODE" = account ]; then SCENARIOS=("${ACCOUNT_SCENARIOS[@]:0:$THROUGH}"); fi

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
AUTH_HEADER="$(umask 077; mktemp "${TMPDIR:-/tmp}/tr-sync-auth.XXXXXX")"
SECRETS_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/tr-sync-secrets.XXXXXX")"
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

# Prints "<vault>\t<dev|account>" for the vaults a ledger created and never marked cleaned; exits non-zero on a malformed line.
# A vault is an account vault if any of its lines says `"account":true` (older lines have no such field). Callers must read the
# output with `x="$(uncleaned_in ...)" || ...`, since a pipe or process substitution hides the exit status.
uncleaned_in() {
  python3 -I -c '
import json, sys
state = {}
account = set()
n = 0
try:
    for n, line in enumerate(open(sys.argv[1]), 1):
        line = line.strip()
        if line:
            entry = json.loads(line)
            state[entry["vault"]] = entry["state"]
            if entry.get("account") is True:
                account.add(entry["vault"])
except (OSError, ValueError, KeyError, TypeError) as e:
    sys.exit("Malformed ledger %s (line %d): %s" % (sys.argv[1], n, e))
for v, s in state.items():
    if s != "cleaned":
        print("%s\t%s" % (v, "account" if v in account else "dev"))' "$1"
}

ledger_add() { # ledger_add <ledger> <vault> <created|cleaned> [account]
  local account=""
  [ "${4:-}" != account ] || account=',"account":true'
  printf '{"vault":"%s","state":"%s"%s,"at":"%s"}\n' "$2" "$3" "$account" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$1"
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

# Deletes the account that owns an account vault (dev-only route). 200 or a 404 from the server itself (no such vault, no account,
# or already deleted) is success; the status code is left in DELETE_ACCOUNT_CODE. API Gateway's missing-route 404 has a
# "message" body and no "error", and is a failure.
DELETE_ACCOUNT_CODE=""
delete_account() {
  local body="$RUN_DIR/delete-account-response.json"
  DELETE_ACCOUNT_CODE="$(curl -s -o "$body" -w '%{http_code}' --max-time 30 -X POST -H "@$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d '{}' "${API_URL}/dev/vaults/$1/delete-account" 2>/dev/null || true)"
  [ "$DELETE_ACCOUNT_CODE" = "200" ] && return 0
  [ "$DELETE_ACCOUNT_CODE" = "404" ] || return 1
  python3 -I -c '
import json, sys
try:
    sys.exit(0 if "error" in json.load(open(sys.argv[1])) else 1)
except Exception:
    sys.exit(1)' "$body"
}

# Set once A6 passed: the cleanup's delete-account must then find nothing to delete.
EXPECT_ACCOUNT_GONE=0
ACCOUNT_NOT_DELETED=0

# Cleans one vault on the server: an account vault's account first, then the erase. Returns non-zero if either failed.
clean_vault() { # clean_vault <vault> <dev|account>
  if [ "$2" = account ]; then
    delete_account "$1" || { echo "Couldn't delete the account of vault $1 on the server." >&2; return 1; }
    if [ "$EXPECT_ACCOUNT_GONE" -eq 1 ] && [ "$DELETE_ACCOUNT_CODE" = "200" ]; then
      echo "FAIL: delete-account still found an account for vault $1 after A6, so Delete sync data didn't delete it." >&2
      ACCOUNT_NOT_DELETED=1
    fi
  fi
  erase_vault "$1"
}

# Cleans every uncleaned vault in a ledger and marks them; returns non-zero if any failed.
clean_ledger() {
  local ledger="$1" vault kind failed=0 pending
  pending="$(uncleaned_in "$ledger")" || return 1
  while IFS=$'\t' read -r vault kind; do
    [ -n "$vault" ] || continue
    if clean_vault "$vault" "$kind"; then
      if [ "$kind" = account ]; then ledger_add "$ledger" "$vault" cleaned account; else ledger_add "$ledger" "$vault" cleaned; fi
    else
      echo "Couldn't clean up vault $vault on the server." >&2
      failed=1
    fi
  done <<<"$pending"
  return "$failed"
}

# Every secret to keep out of the run directory, one per line: the dev secret, the vault keys, and the invites and recovery codes
# the coordinator kept in SECRETS_FILE.
secret_values() {
  printf '%s\n' "$SECRET" ${RUN_KEYS[@]+"${RUN_KEYS[@]}"}
  if [ -s "$SECRETS_FILE" ]; then
    grep -v '^$' "$SECRETS_FILE"
    # A distinctive prefix of each secret too: logs can hold a typed secret truncated or split.
    awk 'NF { s = $0; p = "thoughtreps-pair:v1:"; if (index(s, p) == 1) s = substr(s, length(p) + 1); print substr(s, 1, 24) }' "$SECRETS_FILE"
  fi
  return 0
}

# Overwrites every occurrence of those secrets under the run directory with same-length '*', so
# binary files (.xcresult bundles) keep their offsets. Values travel by environment, never argv; never printed.
redact_secrets() {
  [ -n "$SECRET" ] || return 0
  TR_REDACT_VALUES="$(secret_values)" python3 -I - "$RUN_DIR" <<'PY' \
    || echo "WARNING: redacting secrets in $RUN_DIR failed." >&2
import os, sys
values = sorted({v.encode() for v in os.environ["TR_REDACT_VALUES"].split("\n") if v}, key=len, reverse=True)
for root, _, names in os.walk(sys.argv[1]):
    for name in names:
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
            out = data
            for v in values:
                out = out.replace(v, b"*" * len(v))
            if out != data:
                with open(path, "r+b") as f:
                    f.write(out)
        except Exception:
            pass
PY
}

# Redacts, then names any files in the run directory that still contain a secret; returns 1 if any.
check_secrets_at_rest() {
  local found
  [ -n "$SECRET" ] || return 0
  redact_secrets
  found="$(grep -rlF -f <(secret_values) "$RUN_DIR" 2>/dev/null)"
  [ -z "$found" ] && return 0
  printf 'FAIL: the dev secret, a vault key, an invite or a recovery code is still in these files after redaction:\n%s\n' "$found" >&2
  return 1
}

cleanup() {
  local status=$? pid status_reset_failed=0
  trap - EXIT
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null; done
  for pid in ${CHILDREN[@]+"${CHILDREN[@]}"}; do wait "$pid" 2>/dev/null; done
  if [ "$MODE" = account ] && [ "$DEVICES_TOUCHED" -eq 1 ]; then
    end_reset_devices || { [ "$status" -ne 0 ] || status=1; }
  fi
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
  check_secrets_at_rest || [ "$status" -ne 0 ] || status=1
  rm -f "$AUTH_HEADER" "$SECRETS_FILE"
  [ "$ACCOUNT_NOT_DELETED" -eq 0 ] || [ "$status" -ne 0 ] || status=1
  [ "$ACCOUNT_UNLEDGERED" -eq 0 ] || [ "$status" -ne 0 ] || status=1
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
  local ledger vault kind swept=0 pending
  for ledger in "$TMP_BASE"/run-*/ledger.jsonl; do
    [ -f "$ledger" ] && [ "$ledger" != "$LEDGER" ] || continue
    pending="$(uncleaned_in "$ledger")" || die "Can't read $ledger; fix or delete that run directory and rerun."
    while IFS=$'\t' read -r vault kind; do
      [ -n "$vault" ] || continue
      echo "Sweeping vault $vault left by an earlier run ($(dirname "$ledger"))."
      clean_vault "$vault" "$kind" || die "Couldn't clean up leftover vault $vault; fix the dev stack access and rerun."
      if [ "$kind" = account ]; then ledger_add "$ledger" "$vault" cleaned account; else ledger_add "$ledger" "$vault" cleaned; fi
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
  python3 -I "$ROOT/scripts/sync-coordinator.py" "$ip" "$token" "$SECRETS_FILE" >"$RUN_DIR/coordinator.log" 2>&1 &
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

# MARK: Account scenarios

ACTION_PRINTED=0
MAYBE_PRINTED=0
ACCOUNT_VAULT=""
VAULT_SIGNALLED=0
A1_PASSED=0
ACCOUNT_UNLEDGERED=0
VAULT_PROBLEM=""
A5_SKIPPED=0

# Records the account vault device A reported (marker `account-vault` of the given scenario) in the ledger, once. The id is
# checked before it goes into a JSON line.
record_account_vault() {
  local vault problem=""
  vault="$(curl -s --max-time 3 "$COORD_URL/$1/account-vault" 2>/dev/null)" || problem="couldn't read the account-vault marker"
  if [ -z "$problem" ]; then
    case "$vault" in "" | *[!A-Za-z0-9_-]*) problem="the account-vault marker isn't a plain vault id" ;; esac
    [ -n "$problem" ] || [ "${#vault}" -le 64 ] || problem="the account-vault marker is too long"
  fi
  if [ -n "$problem" ]; then
    [ "$problem" = "$VAULT_PROBLEM" ] || echo "WARNING: $problem; retrying on later polls." >&2
    VAULT_PROBLEM="$problem"
    return 0
  fi
  ACCOUNT_VAULT="$vault"
  ledger_add "$LEDGER" "$vault" created account
  echo "Account vault: $vault"
}

# Reads the coordinator's marker counts: prints an ACTION line for each Sign in with Apple request not yet shown, and records
# the account vault in the ledger the first time it appears.
poll_account_markers() {
  local listing parsed kind arg
  listing="$(curl -s --max-time 3 "$COORD_URL" 2>/dev/null)" || return 0
  parsed="$(printf '%s' "$listing" | python3 -I -c '
import json, sys
try:
    counts = json.load(sys.stdin)
    print("siwa", sum(int(n) for k, n in counts.items() if k.endswith("/action-siwa-a")))
    print("maybe", sum(int(n) for k, n in counts.items() if k.endswith("/action-siwa-a-maybe")))
    for k in counts:
        if k.endswith("/account-vault"):
            print("vault", k.split("/")[0])
except (ValueError, AttributeError, TypeError):
    pass' 2>/dev/null)" || return 0
  while read -r kind arg; do
    case "$kind" in
      siwa)
        while [ "$ACTION_PRINTED" -lt "$arg" ]; do
          echo "ACTION: approve Sign in with Apple on $(printf '%s' "$(device_line "$UDID_A")" | cut -f3)"
          ACTION_PRINTED=$((ACTION_PRINTED + 1))
        done
        ;;
      maybe)
        while [ "$MAYBE_PRINTED" -lt "$arg" ]; do
          echo "ACTION: if a Sign in with Apple sheet appears on $(printf '%s' "$(device_line "$UDID_A")" | cut -f3), approve it"
          MAYBE_PRINTED=$((MAYBE_PRINTED + 1))
        done
        ;;
      vault)
        VAULT_SIGNALLED=1
        [ -n "$ACCOUNT_VAULT" ] || record_account_vault "$arg"
        ;;
    esac
  done <<<"$parsed"
}

run_account_device() { # run_account_device <role> <udid> <dir> <scenario>...
  local role="$1" udid="$2" dir="$3" only=() scenario
  shift 3
  for scenario in "$@"; do only+=("-only-testing:ThoughtRepsUITests/SyncAccountScenarioTests/$scenario"); done
  TEST_RUNNER_TR_SYNC_ROLE="$role" TEST_RUNNER_TR_SYNC_COORDINATOR="$COORD_URL" \
    exec xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$udid" \
    "${only[@]}" -parallel-testing-enabled NO -resultBundlePath "$dir/device-$role.xcresult" >"$dir/device-$role.log" 2>&1
}

# passed, failed, skipped or none: the last result line for a method in a device's log.
result_in_log() { # result_in_log <log> <method>
  local line
  line="$(grep -E "Test [Cc]ase '.*SyncAccountScenarioTests.*$2.*' (passed|failed|skipped)" "$1" 2>/dev/null | tail -1)"
  case "$line" in
    *"' passed"*) echo passed ;;
    *"' failed"*) echo failed ;;
    *"' skipped"*) echo skipped ;;
    *) echo none ;;
  esac
}

# Runs scenarios in order on both devices at once, one xcodebuild each, watching the coordinator while they run, then pulls the
# status snapshots and redacts. Judging the results is check_leg's job.
run_leg() { # run_leg <leg name> <scenario>...
  local leg="$1" dir="$RUN_DIR/$1" elapsed=0 limit pid_a pid_b
  shift
  mkdir -p "$dir"
  limit=$((SCENARIO_TIMEOUT * 2 * $#))
  echo "--- $leg: $*"
  run_account_device a "$UDID_A" "$dir" "$@" &
  pid_a=$!
  run_account_device b "$UDID_B" "$dir" "$@" &
  pid_b=$!
  CHILDREN=("$pid_a" "$pid_b")
  while kill -0 "$pid_a" 2>/dev/null || kill -0 "$pid_b" 2>/dev/null; do
    if [ "$elapsed" -ge "$limit" ]; then
      echo "Timed out after ${limit} s; stopping this leg's test runs."
      kill "$pid_a" "$pid_b" 2>/dev/null
      break
    fi
    poll_account_markers
    sleep 2
    elapsed=$((elapsed + 2))
  done
  wait "$pid_a" 2>/dev/null
  wait "$pid_b" 2>/dev/null
  CHILDREN=()
  poll_account_markers
  pull_status "$UDID_A" a "$dir"
  pull_status "$UDID_B" b "$dir"
  redact_secrets
}

ACCOUNT_FIX="Open the Sync lab on device A and tap Delete sync data, or fix the problem and rerun."

# After a leg: notes that the account vault was signalled, or A1 passed, but it never reached the ledger. The end-of-run reset may
# still recover it from device A's key; confirm_vault_ledgered fails the run if nothing did.
UNLEDGERED_SUSPECT=0
END_RESET_DONE=0
verify_vault_ledgered() {
  [ -z "$ACCOUNT_VAULT" ] || return 0
  [ "$VAULT_SIGNALLED" -eq 1 ] || [ "$A1_PASSED" -eq 1 ] || return 0
  [ "$UNLEDGERED_SUSPECT" -eq 0 ] || return 0
  UNLEDGERED_SUSPECT=1
  echo "WARNING: an account vault was created but not recorded in the ledger; will try to recover it from the device's key at the end." >&2
}

# Ledgers the vault of the key a device's end-of-run reset deleted, if it is an account vault this run hasn't ledgered (a Sign in
# with Apple approved after A1 gave up creates one the test never reported). Only the id comes from the result file.
recover_vault_from_reset() { # recover_vault_from_reset <udid>
  local result="$RUN_DIR/reset-$1.json" vault
  [ -f "$result" ] || return 0
  vault="$(python3 -I -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("forgottenVaultID")
    print(v if isinstance(v, str) else "")
except Exception:
    pass' "$result" 2>/dev/null)"
  case "$vault" in "" | test-* | *[!A-Za-z0-9_-]*) return 0 ;; esac
  [ "${#vault}" -le 64 ] || return 0
  grep -qF "\"vault\":\"$vault\"" "$LEDGER" && return 0
  ledger_add "$LEDGER" "$vault" created account
  [ -n "$ACCOUNT_VAULT" ] || ACCOUNT_VAULT="$vault"
  echo "Recovered account vault $vault from the device's key; it will be cleaned up."
}

# The account-mode end of a run: resets both devices (the reset launch deletes the vault key and reports its vault id), recovers
# an unledgered vault from the result files, and fails loudly if a vault was created that neither path found. Must run before the
# ledger is cleaned. Returns non-zero if a reset failed.
end_reset_devices() {
  local failed=0
  [ "$END_RESET_DONE" -eq 0 ] || return 0
  reset_device "$UDID_A" >/dev/null 2>&1 || { echo "Couldn't reset device A; the next run's preflight will check." >&2; failed=1; }
  reset_device "$UDID_B" >/dev/null 2>&1 || { echo "Couldn't reset device B; the next run's preflight will check." >&2; failed=1; }
  recover_vault_from_reset "$UDID_A"
  recover_vault_from_reset "$UDID_B"
  confirm_vault_ledgered
  END_RESET_DONE=1
  DEVICES_TOUCHED=0
  return "$failed"
}

confirm_vault_ledgered() {
  [ "$UNLEDGERED_SUSPECT" -eq 1 ] && [ -z "$ACCOUNT_VAULT" ] || return 0
  ACCOUNT_UNLEDGERED=1
  echo "FAIL: an account vault was created but never recorded in the ledger, so nothing will clean it up." >&2
  echo "  An account may be left on dev; $ACCOUNT_FIX" >&2
  return 0
}

# Prints PASS, SKIP or FAIL per scenario of a leg, in order, and returns 1 at the first failure (the rest depend on its state).
# A5 skipping on both devices is not a failure: the Keychain item didn't survive the reinstall, which the run reports.
check_leg() { # check_leg <leg name> <scenario>...
  local dir="$RUN_DIR/$1" scenario result_a result_b role
  shift
  for scenario in "$@"; do
    result_a="$(result_in_log "$dir/device-a.log" "$scenario")"
    result_b="$(result_in_log "$dir/device-b.log" "$scenario")"
    if [ "$result_a" = passed ] && [ "$result_b" = passed ]; then
      echo "PASS $scenario"
      [ "$scenario" != testA6_deleteSyncData ] || EXPECT_ACCOUNT_GONE=1
      [ "$scenario" != testA1_createAndInviteJoinMerge ] || A1_PASSED=1
    elif [ "$result_a" = skipped ] && [ "$result_b" = skipped ] && [ "$scenario" = testA5_reinstallResume ]; then
      echo "SKIP $scenario (the Keychain item didn't survive the reinstall; B rejoined by recovery code)"
      A5_SKIPPED=1
    else
      echo "FAIL $scenario (device A: $result_a, device B: $result_b)"
      if [ "$scenario" = testA1_createAndInviteJoinMerge ]; then
        echo "  WARNING: if A1 failed while waiting for Sign in with Apple, approving the sheet late can still create an account on dev."
        echo "  $ACCOUNT_FIX"
      fi
      for role in a b; do
        echo "  device $role failures:"
        grep -E "error:|failed|Test Case .* (failed|skipped)" "$dir/device-$role.log" | head -8 | sed 's/^/    /'
      done
      echo "  logs: $dir"
      return 1
    fi
  done
}

# The two status snapshots of a leg must show the same end state.
pass_check() { # pass_check <leg name> <what>
  local mismatch
  mismatch="$(python3 -I "$ROOT/scripts/sync-pass-check.py" "$RUN_DIR/$1/status-a.json" "$RUN_DIR/$1/status-b.json")" && return 0
  echo "FAIL $2 (the tests passed, but the devices did not end in the same state)"
  printf '%s\n' "$mismatch" | sed 's/^/    /'
  echo "  logs: $RUN_DIR/$1"
  return 1
}

# Uninstalls and installs the app again without the reset launch, so the Keychain vault key stays.
reinstall_app() { # reinstall_app <udid>
  dc device uninstall app --device "$1" --timeout 60 "$APP_BUNDLE_ID" >>"$RUN_DIR/devicectl.log" 2>&1 \
    || { echo "Couldn't uninstall the app from $1 (see $RUN_DIR/devicectl.log)." >&2; return 1; }
  dc device install app --device "$1" --timeout 120 "$APP_PATH" >>"$RUN_DIR/devicectl.log" 2>&1 \
    || { echo "Couldn't install the app on $1 (see $RUN_DIR/devicectl.log)." >&2; return 1; }
}

# The account chain: A1 to A4 (leg 1), a reinstall of the app on B, then A5 and A6 (leg 2). Returns 1 on the first failure.
run_account() {
  local leg1=() leg2=() scenario n=0
  for scenario in "${SCENARIOS[@]}"; do
    n=$((n + 1))
    if [ "$n" -le 4 ]; then leg1+=("$scenario"); else leg2+=("$scenario"); fi
  done
  echo "Account run: approve Sign in with Apple on device A when asked; keep both devices unlocked."
  curl -s -o /dev/null --max-time 5 -X DELETE "$COORD_URL"
  run_leg account-leg1 "${leg1[@]}"
  check_leg account-leg1 "${leg1[@]}"
  local leg1_status=$?
  verify_vault_ledgered
  [ "$leg1_status" -eq 0 ] || return 1
  if [ "${#leg1[@]}" -eq 4 ]; then pass_check account-leg1 "A1 to A4" || return 1; fi
  [ "${#leg2[@]}" -gt 0 ] || return 0
  echo "--- reinstalling the app on device B (Keychain item kept)"
  reinstall_app "$UDID_B" || return 1
  run_leg account-leg2 "${leg2[@]}"
  check_leg account-leg2 "${leg2[@]}"
  local leg2_status=$?
  verify_vault_ledgered
  [ "$leg2_status" -eq 0 ] || return 1
  if [ "${#leg2[@]}" -eq 1 ]; then pass_check account-leg2 "A5" || return 1; fi
  return 0
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
  redact_secrets
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
if [ "$MODE" = account ]; then
  run_account || FAILED=$((FAILED + 1))
else
  for scenario in "${SCENARIOS[@]}"; do
    run_scenario "$scenario" || FAILED=$((FAILED + 1))
  done
fi

if [ "$MODE" = account ]; then end_reset_devices || FAILED=$((FAILED + 1)); fi

clean_ledger "$LEDGER" || FAILED=$((FAILED + 1))
[ "$ACCOUNT_NOT_DELETED" -eq 0 ] || FAILED=$((FAILED + 1))
[ "$ACCOUNT_UNLEDGERED" -eq 0 ] || FAILED=$((FAILED + 1))
if ! LEFT="$(uncleaned_in "$LEDGER")"; then
  FAILED=$((FAILED + 1))
elif [ -n "$LEFT" ]; then
  echo "FAIL: cleanup left vault(s) on the server: $(printf '%s\n' "$LEFT" | cut -f1 | tr '\n' ' ')"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  if [ "$A5_SKIPPED" -eq 1 ]; then
    echo "PASS (A5 skipped: the Keychain item didn't survive the reinstall): ${#SCENARIOS[@]} scenario(s), every ledger entry cleaned. Logs: $RUN_DIR"
  else
    echo "PASS: ${#SCENARIOS[@]} scenario(s), every ledger entry cleaned. Logs: $RUN_DIR"
  fi
else
  echo "FAIL: $FAILED problem(s) in ${#SCENARIOS[@]} scenario(s) or cleanup. Logs: $RUN_DIR"
  exit 1
fi
