# Testing

Screen Recorder uses macOS privacy-protected APIs, so automated CI can verify
builds and packaging, while real recording behavior must be checked on a Mac
with Screen Recording and Microphone permissions granted.

## Automated checks

Run:

```bash
scripts/smoke_test.sh
```

This checks:

- Swift release build
- `.app` bundle creation
- `Info.plist` validity
- ad-hoc code signing
- bundle identifier

## Groq transcription setup

Configure automatic transcription:

```bash
scripts/configure_groq.sh
scripts/doctor.sh
```

When configured, each recording with an audio track should produce a transcript
in `~/Downloads`.

## Manual recording matrix

Install and open the app:

```bash
scripts/install.sh
open "$HOME/Applications/Screen Recorder.app"
```

For each row, enable the listed sources, record for 5-10 seconds, stop, and
verify that a non-empty file appears in `~/Movies/Recordings`.
If Groq is configured, also verify that a non-empty `_transcript.txt` file
appears in `~/Downloads`.

| Screen | Microphone | System Audio | Expected file | Notes |
| --- | --- | --- | --- | --- |
| on | off | off | `.mov` | screen-only capture |
| on | on | off | `.mov` | video plus microphone, needs `ffmpeg` for final mux |
| on | off | on | `.mov` | video plus system audio |
| on | on | on | `.mov` | video plus mixed mic/system audio, needs `ffmpeg` |
| off | on | off | `.m4a` | dictaphone mode |
| off | off | on | `.m4a` | system-audio-only mode |
| off | on | on | `.m4a` | mixed mic/system audio, needs `ffmpeg` |

If a permission prompt does not appear, open:

`System Settings -> Privacy & Security -> Screen Recording`

and:

`System Settings -> Privacy & Security -> Microphone`

Then enable Screen Recorder and restart the app.
