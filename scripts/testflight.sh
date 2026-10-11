#!/usr/bin/env bash
# Archives a Release build and uploads it to App Store Connect (TestFlight).
# The build number is a UTC timestamp (yyyymmdd.hhmm), so every run is higher than the last
# with nothing to commit; MARKETING_VERSION comes from project.yml.
#
# Auth: the Apple account signed into Xcode, unless ASC_KEY_PATH, ASC_KEY_ID
# and ASC_ISSUER_ID are all set (App Store Connect API key).
#
# Usage: scripts/testflight.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LOCAL_XCCONFIG="$REPO_ROOT/Config/Local.xcconfig"
[[ -f "$LOCAL_XCCONFIG" ]] || { echo "$LOCAL_XCCONFIG missing — copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM" >&2; exit 1; }
TEAM_ID=$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Za-z0-9]+).*/\1/p' "$LOCAL_XCCONFIG" | head -n1)
[[ -n "$TEAM_ID" && "$TEAM_ID" != "YOURTEAMID" ]] || { echo "DEVELOPMENT_TEAM is not set in $LOCAL_XCCONFIG" >&2; exit 1; }

if ! git diff --quiet HEAD --; then
  echo "Uncommitted changes to tracked files — commit or stash them first." >&2
  exit 1
fi
echo "==> Building commit $(git log -1 --format='%h %s')"

AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]] \
  && ! [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  echo "Set all of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID, or none to use the Xcode account." >&2
  exit 1
fi
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

# Two components (yyyymmdd.hhmm) keep each part within 32 bits.
BUILD_NUMBER=$(date -u +%Y%m%d.%H%M)
WORK_DIR=$(mktemp -d)
ARCHIVE="$WORK_DIR/ThoughtReps.xcarchive"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
# Keep the archive if anything fails, so a failed upload can be retried from Organizer or by hand.
trap 'echo "Archive kept at $ARCHIVE" >&2' ERR

echo "==> Generating the Xcode project"
xcodegen

echo "==> Archiving build $BUILD_NUMBER"
xcodebuild archive \
  -scheme ThoughtReps \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
plutil -lint "$EXPORT_OPTIONS" >/dev/null

echo "==> Exporting and uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$WORK_DIR/export" \
  -allowProvisioningUpdates \
  ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist")
echo "==> Uploaded version $VERSION build $BUILD_NUMBER"
echo "It appears in TestFlight after Apple's processing (usually 10-30 minutes)."
rm -rf "$WORK_DIR"
