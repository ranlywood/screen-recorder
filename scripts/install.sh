#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$HOME/Applications"
INSTALL_FFMPEG=0
BUILD_ARGS=()

usage() {
  cat <<'USAGE'
Usage: scripts/install.sh [options]

Builds Screen Recorder and installs it for the current macOS user.

Options:
  --destination DIR      Install into DIR (default: ~/Applications)
  --install-ffmpeg       Install ffmpeg with Homebrew when it is missing
  --clean                Clean Swift build cache first
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      DEST_DIR="$2"
      shift 2
      ;;
    --install-ffmpeg)
      INSTALL_FFMPEG=1
      shift
      ;;
    --clean)
      BUILD_ARGS+=(--clean)
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
  echo "Screen Recorder is macOS-only." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1 \
  && [[ ! -x /opt/homebrew/bin/ffmpeg ]] \
  && [[ ! -x /usr/local/bin/ffmpeg ]] \
  && [[ ! -x /opt/local/bin/ffmpeg ]]; then
  if [[ "$INSTALL_FFMPEG" -eq 1 ]]; then
    if command -v brew >/dev/null 2>&1; then
      brew install ffmpeg
    else
      echo "Homebrew is required for --install-ffmpeg. Install ffmpeg manually or continue without mixed mic exports." >&2
    fi
  else
    echo "ffmpeg not found. Mixed microphone + screen/system audio exports need it."
    echo "Install later with: brew install ffmpeg"
  fi
fi

APP_PATH="$("$ROOT_DIR/scripts/build_app.sh" "${BUILD_ARGS[@]}")"
mkdir -p "$DEST_DIR"

TARGET_PATH="$DEST_DIR/Screen Recorder.app"
rm -rf "$TARGET_PATH"
cp -R "$APP_PATH" "$TARGET_PATH"

echo "Installed: $TARGET_PATH"
echo ""
echo "First launch:"
echo "  open \"$TARGET_PATH\""
echo ""
echo "macOS will ask for Screen Recording and Microphone permissions when needed."
echo "Recordings are saved to: $HOME/Movies/Recordings"
echo "Transcripts are saved to: $HOME/Downloads when Groq is configured with scripts/configure_groq.sh"
