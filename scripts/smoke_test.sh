#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/doctor.sh"
APP_PATH="$("$ROOT_DIR/scripts/build_app.sh" --clean)"

test -d "$APP_PATH"
test -x "$APP_PATH/Contents/MacOS/ScreenRecorder"
test -f "$APP_PATH/Contents/Info.plist"
test -f "$APP_PATH/Contents/Resources/AppIcon.icns"

plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "io.github.ranlywood.screenrecorder" ]]; then
  echo "Unexpected bundle id: $BUNDLE_ID" >&2
  exit 1
fi

echo "Smoke test passed: $APP_PATH"
