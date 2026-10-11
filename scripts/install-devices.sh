#!/usr/bin/env bash
# Builds a Debug build once and installs it on every paired iPhone or iPad this
# Mac can reach (USB or Wi-Fi), then launches it. Faster than TestFlight: no
# upload or Apple processing. Devices that are asleep or off the network are
# skipped. Pair over Wi-Fi once per device: plug in, then Xcode > Window >
# Devices and Simulators > "Connect via network".
#
# Usage: scripts/install-devices.sh [name filter, any case]   e.g. scripts/install-devices.sh iPad
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
FILTER=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
DERIVED="$REPO_ROOT/.build/devices"
APP="$DERIVED/Build/Products/Debug-iphoneos/ThoughtReps.app"

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

# "identifier<TAB>name" for each paired physical iOS/iPadOS device.
DEVICES=$(xcrun devicectl list devices --quiet --json-output - | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS" and conn.get("pairingState") == "paired":
        print(d["identifier"] + "\t" + d.get("deviceProperties", {}).get("name", "?"))
')

installed=0
while IFS=$'\t' read -r id name; do
  [[ -n "$id" ]] || continue
  lower_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  if [[ -n "$FILTER" && "$lower_name" != *"$FILTER"* ]]; then continue; fi
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
