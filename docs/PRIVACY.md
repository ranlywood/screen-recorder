# Privacy

Screen Recorder is a local macOS app unless you configure Groq transcription.

- It does not include analytics.
- It writes recordings to `~/Movies/Recordings`.
- It writes transcripts to `~/Downloads`.
- It writes a local diagnostic log to `~/Movies/Recordings/screenrecorder.log`.

If you run `scripts/configure_groq.sh`, the app stores your Groq API key in
macOS Keychain. After each finished recording, it extracts/transcodes the audio
when needed, uploads audio to Groq's transcription endpoint, and writes a local
`.txt` transcript. No transcript is attempted when the key is missing.

The app asks macOS for Screen Recording permission when screen or system-audio
capture is used. It asks for Microphone permission when microphone recording is
enabled.

System audio is captured through Apple's ScreenCaptureKit. Microphone audio is
captured through AVFoundation.
