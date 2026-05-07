#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0

note() {
  printf '%s\n' "$1"
}

check_required() {
  local name="$1"
  local command="$2"

  if command -v "$command" >/dev/null 2>&1; then
    note "[ok] $name: $(command -v "$command")"
  else
    note "[missing] $name"
    failures=$((failures + 1))
  fi
}

note "Screen Recorder environment check"
note ""

if [[ "$(uname -s)" != "Darwin" ]]; then
  note "[missing] macOS is required. Screen Recorder uses Apple's ScreenCaptureKit."
  failures=$((failures + 1))
else
  note "[ok] macOS: $(sw_vers -productVersion)"
fi

check_required "Swift toolchain" swift
check_required "codesign" codesign
check_required "plutil" plutil

if [[ -n "${SCREENRECORDER_FFMPEG:-}" && -x "$SCREENRECORDER_FFMPEG" ]]; then
  note "[ok] ffmpeg: $SCREENRECORDER_FFMPEG"
elif command -v ffmpeg >/dev/null 2>&1; then
  note "[ok] ffmpeg: $(command -v ffmpeg)"
elif [[ -x /opt/homebrew/bin/ffmpeg ]]; then
  note "[ok] ffmpeg: /opt/homebrew/bin/ffmpeg"
elif [[ -x /usr/local/bin/ffmpeg ]]; then
  note "[ok] ffmpeg: /usr/local/bin/ffmpeg"
elif [[ -x /opt/local/bin/ffmpeg ]]; then
  note "[ok] ffmpeg: /opt/local/bin/ffmpeg"
else
  note "[warn] ffmpeg not found. Screen-only, system-audio-only, and mic-only modes still work; mixed mic+screen/audio exports need ffmpeg."
  note "       Install with: brew install ffmpeg"
fi

note ""

if [[ "$failures" -gt 0 ]]; then
  note "Doctor failed with $failures missing required item(s)."
  exit 1
fi

note "Doctor passed."
