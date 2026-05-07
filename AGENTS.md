# Agent Install Guide

Use this file when installing Screen Recorder through Codex, Claude Code, or a
similar local coding agent.

## Goal

Install a free, local, macOS-only screen recorder that can record:

- screen video
- microphone audio
- system audio
- microphone-only voice notes
- system-audio-only clips

## Safe install commands

Run these commands from the cloned repository:

```bash
scripts/doctor.sh
scripts/install.sh
```

If the user wants mixed microphone + system/screen exports and `ffmpeg` is
missing, run:

```bash
scripts/install.sh --install-ffmpeg
```

## Validation

Run:

```bash
scripts/smoke_test.sh
```

Do not run the app binary directly in the terminal as a test; it starts a GUI
event loop. Launch it with:

```bash
open "$HOME/Applications/Screen Recorder.app"
```

## Platform boundary

This app is macOS-only. Do not attempt to install it on Windows or Linux.
It requires macOS 13 or newer because it uses ScreenCaptureKit.

## Privacy boundary

The app has no cloud backend and no analytics. Recordings and logs stay under
`~/Movies/Recordings`.
