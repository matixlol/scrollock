#!/usr/bin/env bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null; then
  echo 'Safari native packaging requires macOS and Xcode. Alternatively upload a ZIP of dist/safari to the Safari Web Extension Packager in App Store Connect.' >&2
  exit 1
fi
if [[ ! -f "$ROOT/dist/safari/manifest.json" ]]; then
  echo 'Run API_ORIGIN=https://your-server.example npm run build first.' >&2
  exit 1
fi
xcrun safari-web-extension-packager "$ROOT/dist/safari" \
  --project-location "$ROOT/safari" \
  --app-name Scrollock \
  --bundle-identifier "${SAFARI_BUNDLE_ID:-ar.com.poronga.Scrollock}" \
  --ios-only --swift --no-open
echo 'Open the generated Xcode project, select your signing team on both targets, then build and run on your iPhone.'
