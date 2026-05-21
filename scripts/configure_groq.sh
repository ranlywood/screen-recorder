#!/usr/bin/env bash
set -euo pipefail

SERVICE="io.github.ranlywood.screenrecorder"
ACCOUNT="GROQ_API_KEY"

usage() {
  cat <<'USAGE'
Usage: scripts/configure_groq.sh [--status|--clear]

Stores the Groq API key in macOS Keychain so the Screen Recorder app can
transcribe recordings after it is launched from Finder.

If GROQ_API_KEY is present in the environment, this script uses it. Otherwise
it prompts securely.
USAGE
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Groq keychain configuration is macOS-only." >&2
  exit 1
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --status)
    if [[ -n "${GROQ_API_KEY:-}" ]]; then
      echo "Groq API key is available from GROQ_API_KEY environment variable."
    elif security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w >/dev/null 2>&1; then
      echo "Groq API key is stored in macOS Keychain."
    else
      echo "Groq API key is not configured."
      exit 1
    fi
    exit 0
    ;;
  --clear)
    security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1 || true
    echo "Groq API key removed from macOS Keychain."
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
esac

api_key="${GROQ_API_KEY:-}"

if [[ -z "$api_key" ]]; then
  printf "Paste Groq API key: "
  stty -echo
  read -r api_key
  stty echo
  printf "\n"
fi

if [[ -z "$api_key" ]]; then
  echo "No API key provided." >&2
  exit 1
fi

security add-generic-password -U -s "$SERVICE" -a "$ACCOUNT" -w "$api_key" >/dev/null
echo "Groq API key stored in macOS Keychain for Screen Recorder."
