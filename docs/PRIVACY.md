# Privacy

Screen Recorder is a local macOS app.

- It does not include analytics.
- It does not make network requests.
- It does not upload recordings.
- It writes recordings to `~/Movies/Recordings`.
- It writes a local diagnostic log to `~/Movies/Recordings/screenrecorder.log`.

The app asks macOS for Screen Recording permission when screen or system-audio
capture is used. It asks for Microphone permission when microphone recording is
enabled.

System audio is captured through Apple's ScreenCaptureKit. Microphone audio is
captured through AVFoundation.
