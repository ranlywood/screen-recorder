#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ScreenRecorder"
DISPLAY_NAME="Screen Recorder"
DIST_DIR="$ROOT_DIR/.dist"
APP_PATH="$DIST_DIR/$DISPLAY_NAME.app"
CONFIGURATION="release"
SKIP_CODESIGN=0
CLEAN=0

usage() {
  cat <<'USAGE'
Usage: scripts/build_app.sh [options]

Builds Screen Recorder as a macOS .app bundle.

Options:
  --output DIR       Put the .app bundle in DIR instead of .dist
  --debug            Build the Swift debug configuration
  --release          Build the Swift release configuration (default)
  --clean            Remove the Swift build cache before building
  --skip-codesign    Do not sign the app bundle
  -h, --help         Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      DIST_DIR="$2"
      APP_PATH="$DIST_DIR/$DISPLAY_NAME.app"
      shift 2
      ;;
    --debug)
      CONFIGURATION="debug"
      shift
      ;;
    --release)
      CONFIGURATION="release"
      shift
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --skip-codesign)
      SKIP_CODESIGN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Screen Recorder can only be built on macOS." >&2
  exit 1
fi

if [[ "$CLEAN" -eq 1 ]]; then
  swift package clean
fi

swift build -c "$CONFIGURATION" >&2

BINARY_PATH="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Build output missing: $BINARY_PATH" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

install -m 755 "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
install -m 644 "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
install -m 644 "$ROOT_DIR/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

if [[ "$SKIP_CODESIGN" -eq 0 ]]; then
  codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/Resources/ScreenRecorder.entitlements" \
    "$APP_PATH"
fi

echo "$APP_PATH"
