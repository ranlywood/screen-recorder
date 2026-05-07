# Screen Recorder

Free, local screen recorder for macOS.

Screen Recorder records your screen, microphone, and system audio in separate
combinations. It is useful for meeting notes, tutorials, YouTube voiceovers,
capturing a short audio reference from another app, or using your Mac as a
simple dictaphone.

## Features

- Screen recording to `.mov`
- Microphone recording
- System audio recording through ScreenCaptureKit
- Microphone-only voice notes to `.m4a`
- System-audio-only recording to `.m4a`
- Optional mixed microphone + system audio exports
- Local recordings folder at `~/Movies/Recordings`
- No analytics, no account, no upload

## Requirements

- macOS 13 Ventura or newer
- Swift toolchain or Xcode Command Line Tools
- `ffmpeg` for final exports that mix microphone audio with screen/system audio

Screen-only, microphone-only, system-audio-only, and screen+system-audio modes
do not require `ffmpeg`.

## Quick Install

```bash
git clone https://github.com/ranlywood/screen-recorder.git
cd screen-recorder
scripts/install.sh
open "$HOME/Applications/Screen Recorder.app"
```

If you want the installer to install `ffmpeg` with Homebrew when it is missing:

```bash
scripts/install.sh --install-ffmpeg
```

The app is installed to `~/Applications/Screen Recorder.app` by default.

## Install With Codex Or Claude Code

Give your local coding agent this prompt:

```text
Clone https://github.com/ranlywood/screen-recorder, read AGENTS.md, run scripts/doctor.sh, run scripts/install.sh, and then run scripts/smoke_test.sh. If ffmpeg is missing and Homebrew is available, rerun install with --install-ffmpeg. Do not upload any recordings or local files.
```

## Build Manually

```bash
scripts/doctor.sh
scripts/build_app.sh
```

The built app appears in:

```text
.dist/Screen Recorder.app
```

To install somewhere else:

```bash
scripts/install.sh --destination /path/to/Applications
```

## First Launch Permissions

macOS controls screen, system audio, and microphone capture permissions.
On first use, grant the requested permissions in:

```text
System Settings -> Privacy & Security -> Screen Recording
System Settings -> Privacy & Security -> Microphone
```

Restart Screen Recorder after changing permissions.

## Recording Modes

| Screen | Microphone | System Audio | Output |
| --- | --- | --- | --- |
| on | off | off | `.mov` screen recording |
| on | on | off | `.mov` screen + mic |
| on | off | on | `.mov` screen + system audio |
| on | on | on | `.mov` screen + mixed mic/system audio |
| off | on | off | `.m4a` microphone voice note |
| off | off | on | `.m4a` system audio |
| off | on | on | `.m4a` mixed mic/system audio |

## Privacy

Screen Recorder is local-first:

- no analytics
- no accounts
- no network upload
- recordings saved to `~/Movies/Recordings`
- diagnostic log saved to `~/Movies/Recordings/screenrecorder.log`

See [docs/PRIVACY.md](docs/PRIVACY.md).

## Testing

```bash
scripts/smoke_test.sh
```

Manual recording checks are documented in [docs/TESTING.md](docs/TESTING.md).

## macOS Only

Screen Recorder is not a Windows or Linux app. It depends on Apple's
ScreenCaptureKit and AVFoundation APIs.

## License

MIT
