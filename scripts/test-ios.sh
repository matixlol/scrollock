#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
  echo "iOS checks require macOS with Xcode installed." >&2
  exit 1
fi
cd "$ROOT"
if [[ ! -f dist/safari/manifest.json ]]; then npm run build; fi
swift test --package-path ios/ScrollockKit
# Compile every target. Screen Time shields are not enforced in the simulator,
# so blocking itself must be checked on a device.
xcodebuild \
  -project ios/Scrollock.xcodeproj \
  -scheme Scrollock \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
