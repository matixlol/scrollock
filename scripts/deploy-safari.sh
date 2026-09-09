#!/usr/bin/env bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
TEAM_ID="${APPLE_TEAM_ID:-BQ7842UUHJ}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scrollock-safari.XXXXXX")"
trap 'rm -rf "$ARCHIVE_DIR"' EXIT

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo "Safari deployment requires macOS with Xcode installed." >&2
  exit 1
fi

cd "$ROOT"
npm ci
npm test
npm run check
npm run build:production

# This project is generated from dist/safari; do not preserve local edits in it.
rm -rf safari
SAFARI_BUNDLE_ID=ar.com.poronga.Scrollock npm run safari:package

cat > "$ARCHIVE_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

plutil -lint "$ARCHIVE_DIR/ExportOptions.plist"
xcodebuild \
  -project safari/Scrollock/Scrollock.xcodeproj \
  -scheme Scrollock \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_DIR/Scrollock.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_DIR/Scrollock.xcarchive" \
  -exportPath "$ARCHIVE_DIR/export" \
  -exportOptionsPlist "$ARCHIVE_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates

echo "Uploaded Safari build $BUILD_NUMBER to App Store Connect/TestFlight."
