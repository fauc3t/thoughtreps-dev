#!/usr/bin/env bash
# Builds a Debug build once and installs it on every paired iPhone or iPad this
# Mac can reach (USB or Wi-Fi), then launches it. Faster than TestFlight: no
# upload or Apple processing. Devices that are asleep or off the network are
# skipped. Pair over Wi-Fi once per device: plug in, then Xcode > Window >
# Devices and Simulators > "Connect via network".
#
# Usage: scripts/install-devices.sh [UDID ...]   all paired devices, or only these
#        scripts/install-devices.sh --list      paired devices and their UDIDs
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
DERIVED="$REPO_ROOT/.build/devices"
APP="$DERIVED/Build/Products/Debug-iphoneos/ThoughtReps.app"

# "identifier<TAB>UDID<TAB>name<TAB>model" for each paired physical iOS/iPadOS
# device. The UDID is the stable hardware id; the identifier is devicectl's own.
DEVICES=$(xcrun devicectl list devices --quiet --json-output - | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print("\t".join([d["identifier"], hw.get("udid", "?"), d.get("deviceProperties", {}).get("name", "?"), hw.get("marketingName", "?")]))
')

if [[ "${1:-}" == "--list" ]]; then
  while IFS=$'\t' read -r _ udid name model; do
    if [[ -n "$udid" ]]; then printf '%s  %s (%s)\n' "$udid" "$name" "$model"; fi
  done <<< "$DEVICES"
  exit 0
fi

# Fail on an unknown UDID before spending time on the build.
for want in "$@"; do
  if ! cut -f2 <<< "$DEVICES" | grep -qixF -- "$want"; then
    echo "No paired device with UDID $want. Paired devices:" >&2
    "$0" --list >&2
    exit 1
  fi
done

echo "==> Generating the Xcode project"
xcodegen

echo "==> Building Debug for devices"
xcodebuild build \
  -scheme ThoughtReps \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -quiet
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")

installed=0
while IFS=$'\t' read -r id udid name _; do
  [[ -n "$id" ]] || continue
  if [[ $# -gt 0 ]] && ! printf '%s\n' "$@" | grep -qixF -- "$udid"; then continue; fi
  echo "==> $name"
  if ! out=$(xcrun devicectl device install app --quiet --device "$id" "$APP" </dev/null 2>&1); then
    echo "    skipped: install failed (asleep or off this network?)" >&2
    echo "$out" | tail -n 5 | sed 's/^/    /' >&2
    continue
  fi
  installed=$((installed + 1))
  if ! xcrun devicectl device process launch --quiet --terminate-existing --device "$id" "$BUNDLE_ID" </dev/null >/dev/null 2>&1; then
    echo "    installed; not launched (locked?)"
  fi
done <<< "$DEVICES"

echo "==> Installed on $installed device(s)"
[[ $installed -gt 0 ]]
