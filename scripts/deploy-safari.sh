#!/usr/bin/env bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
TEAM_ID="${APPLE_TEAM_ID:-BQ7842UUHJ}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"
APPLE_CREDENTIALS="${APPLE_API_CREDENTIALS:-$HOME/.config/caloric/apple.json}"
ARCHIVE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/scrollock-safari.XXXXXX")"
trap 'rm -rf "$ARCHIVE_DIR"' EXIT

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo "Safari deployment requires macOS with Xcode installed." >&2
  exit 1
fi

if [[ -n "${APPLE_API_CREDENTIALS:-}" && ! -f "$APPLE_CREDENTIALS" ]]; then
  echo "APPLE_API_CREDENTIALS must point to an existing credential JSON file." >&2
  exit 1
fi
if [[ -f "$APPLE_CREDENTIALS" ]]; then
  apple_credential_setting() {
    python3 - "$APPLE_CREDENTIALS" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    value = json.load(file)[sys.argv[2]]
if not isinstance(value, str) or not value or '\n' in value or '\r' in value:
    raise SystemExit('Invalid Apple credential configuration')
print(value)
PY
  }
  ASC_KEY_PATH="${ASC_KEY_PATH:-$(apple_credential_setting keyPath)}"
  ASC_KEY_ID="${ASC_KEY_ID:-$(apple_credential_setting keyID)}"
  ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(apple_credential_setting issuerID)}"
fi
AUTH_ARGS=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID}" "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
  AUTH_ARGS+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
EXPORT_OPTIONS="${SAFARI_EXPORT_OPTIONS:-$HOME/.config/scrollock/ExportOptions.plist}"
if [[ -n "${SAFARI_EXPORT_OPTIONS:-}" && ! -f "$EXPORT_OPTIONS" ]]; then
  echo "SAFARI_EXPORT_OPTIONS must point to an existing export options plist." >&2
  exit 1
fi

cd "$ROOT"
npm ci
npm test
npm run check
npm run build:production

swift test --package-path ios/ScrollockKit

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
if [[ ! -f "$EXPORT_OPTIONS" ]]; then
  EXPORT_OPTIONS="$ARCHIVE_DIR/ExportOptions.plist"
fi
xcodebuild \
  -project ios/Scrollock.xcodeproj \
  -scheme Scrollock \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_DIR/Scrollock.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH_ARGS[@]}" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_DIR/Scrollock.xcarchive" \
  -exportPath "$ARCHIVE_DIR/export" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  "${AUTH_ARGS[@]}"

echo "Uploaded Safari build $BUILD_NUMBER to App Store Connect/TestFlight."
