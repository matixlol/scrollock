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
/usr/libexec/PlistBuddy -c 'Add :ITSAppUsesNonExemptEncryption bool false' \
  "$ROOT/safari/Scrollock/Scrollock/Info.plist"
# Keep the containing app functional and unbranded after every regeneration.
cat > "$ROOT/safari/Scrollock/Scrollock/Resources/Base.lproj/Main.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Extension settings</title>
  <link rel="stylesheet" href="../Style.css">
</head>
<body>
  <p>Enable the extension in Settings → Apps → Safari → Extensions.</p>
</body>
</html>
HTML
python3 "$ROOT/scripts/configure-native.py"
echo 'Open the generated Xcode project, select your signing team on all three targets, then build and run on your iPhone. Distribution requires Family Controls approval.'
