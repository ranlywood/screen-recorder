import Cocoa
import ScreenCaptureKit
import AVFoundation
import Accelerate

let logFileHandle: FileHandle? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("screenrecorder.log")
    FileManager.default.createFile(atPath: path.path, contents: nil)
    return FileHandle(forWritingAtPath: path.path)
}()

func log(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let msg = "[\(timestamp)] \(message)"
    fputs(msg + "\n", stderr)
    logFileHandle?.seekToEndOfFile()
    logFileHandle?.write((msg + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Recorder
class Recorder: NSObject, SCStreamDelegate, SCStreamOutput {
    var onScreenPreview: ((NSImage) -> Void)?
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?

    private var audioEngine: AVAudioEngine?
    private var micFile: AVAudioFile?
    private var tempMicURL: URL?

    private var outputURL: URL?
    private var sessionStarted = false
    private var frameCount = 0

    // Thread-safe access
    private let lock = NSLock()
    private var sessionStartPTS: CMTime?
    private var recordingActivity: NSObjectProtocol?

    private(set) var isRecording = false
    private var isMicOnlyMode = false
    var screenEnabled = true
    var micEnabled = true
    var systemAudioEnabled = true

    private var micOnlyWriter: AVAssetWriter?
    private var micOnlyInput: AVAssetWriterInput?
    private var micOnlyStartTime: CMTime?

    private func beginRecordingActivity() {
        guard recordingActivity == nil else { return }
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Screen recording in progress"
        )
    }

    private func endRecordingActivity() {
        guard let token = recordingActivity else { return }
        ProcessInfo.processInfo.endActivity(token)
        recordingActivity = nil
    }

    /// Configure writer for better crash/interruption recoverability.
    private func configureWriterForResilience(_ writer: AVAssetWriter) {
        writer.shouldOptimizeForNetworkUse = true
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
    }

    /// Mic-only dictaphone: AVAudioEngine -> AVAssetWriter -> .m4a
    @MainActor
    func startMicOnlyRecording() async {
        log("startMicOnlyRecording: isRecording=\(isRecording), isMicOnlyMode=\(isMicOnlyMode)")
        guard !isRecording else {
            log("startMicOnlyRecording: already recording, aborting")
            return
        }

        recordedSystemAudio = false
        recordedMicAudio = true

        // Ensure previous audio engine is fully stopped
        if audioEngine != nil {
            log("startMicOnlyRecording: cleaning up previous audioEngine")
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
        }

        onStatusChange?("Starting dictaphone...")

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        outputURL = dir.appendingPathComponent("Voice_\(timestamp).m4a")

        guard let url = outputURL else { return }
        try? FileManager.default.removeItem(at: url)

        do {
            micOnlyWriter = try AVAssetWriter(outputURL: url, fileType: .m4a)
            if let writer = micOnlyWriter {
                configureWriterForResilience(writer)
            }
        } catch {
            onStatusChange?("Error: \(error.localizedDescription)")
            return
        }

        micOnlyInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 192000
        ])
        micOnlyInput?.expectsMediaDataInRealTime = true
        if let input = micOnlyInput { micOnlyWriter?.add(input) }

        micOnlyWriter?.startWriting()
        micOnlyStartTime = nil

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            onStatusChange?("Failed to create audio engine")
            return
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false) else {
            onStatusChange?("Failed to create target format")
            return
        }

        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, when in
            guard let self = self else { return }

            // Level metering
            if let channelData = buffer.floatChannelData?[0] {
                let frames = buffer.frameLength
                var rms: Float = 0
                vDSP_measqv(channelData, 1, &rms, vDSP_Length(frames))
                rms = sqrt(rms)
                let db = 20 * log10(max(rms, 0.00001))
                let level = max(0, min(1, (db + 50) / 50))
                DispatchQueue.main.async { self.onMicLevel?(level) }
            }

            // Convert to 48kHz mono
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 48000.0 / hwFormat.sampleRate) + 1
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter?.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status == .haveData, error == nil else { return }

            guard let formatDesc = CMAudioFormatDescription.from(audioFormat: targetFormat) else { return }
            let numSamples = CMItemCount(convertedBuffer.frameLength)
            guard numSamples > 0 else { return }

            self.lock.lock()
            let writerRef = self.micOnlyWriter
            let inputRef = self.micOnlyInput
            if self.micOnlyStartTime == nil {
                self.micOnlyStartTime = CMTimeMake(value: Int64(when.sampleTime), timescale: Int32(hwFormat.sampleRate))
                writerRef?.startSession(atSourceTime: .zero)
                log("Mic-only: first sample, started session")
            }
            let baseTime = self.micOnlyStartTime!
            self.lock.unlock()

            let pts = CMTimeSubtract(
                CMTimeMake(value: Int64(when.sampleTime), timescale: Int32(hwFormat.sampleRate)),
                baseTime
            )
            guard pts.seconds >= 0 else { return }

            var timing = CMSampleTimingInfo(
                duration: CMTimeMake(value: Int64(numSamples), timescale: 48000),
                presentationTimeStamp: pts,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            guard let blockData = convertedBuffer.floatChannelData?[0] else { return }
            let dataSize = Int(convertedBuffer.frameLength) * MemoryLayout<Float>.size

            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: dataSize, flags: 0, blockBufferOut: &blockBuffer
            )
            guard let block = blockBuffer else { return }
            CMBlockBufferReplaceDataBytes(with: blockData, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize)

            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
                sampleCount: numSamples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
            )

            if let sb = sampleBuffer, let input = inputRef, input.isReadyForMoreMediaData,
               writerRef?.status == .writing {
                input.append(sb)
            }
        }

        do {
            try engine.start()
            beginRecordingActivity()
            isMicOnlyMode = true
            isRecording = true
            onStatusChange?("Recording (mic only)...")
            onRecordingStateChange?(true)
            log("Mic-only recording started -> \(url.lastPathComponent)")
        } catch {
            onStatusChange?("Mic error: \(error.localizedDescription)")
            micOnlyWriter = nil
            micOnlyInput = nil
        }
    }

    /// Stop mic-only recording
    @MainActor
    func stopMicOnlyRecording() async {
        guard isRecording, isMicOnlyMode else { return }

        onStatusChange?("Stopping...")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        micOnlyInput?.markAsFinished()
        if let w = micOnlyWriter, w.status == .writing {
            await w.finishWriting()
            log("Mic-only writer finished, status: \(w.status.rawValue)")
        }

        micOnlyWriter = nil
        micOnlyInput = nil
        micOnlyStartTime = nil

        isRecording = false
        isMicOnlyMode = false
        recordedSystemAudio = false
        recordedMicAudio = false
        endRecordingActivity()
        onRecordingStateChange?(false)

        if let url = outputURL {
            onStatusChange?("Saved!")
            log("Mic-only saved: \(url.path)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var isAudioOnlyMode = false
    private var recordedSystemAudio = false
    private var recordedMicAudio = false

    private func ffmpegExecutableURL() -> URL? {
        if let configuredPath = ProcessInfo.processInfo.environment["SCREENRECORDER_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return URL(fileURLWithPath: configuredPath)
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        log("ffmpeg binary not found in known locations")
        return nil
    }

    private func ffmpegFailureOutput(from process: Process, pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return "no stderr output"
        }
        let output = String(data: data, encoding: .utf8) ?? "stderr decode failed"
        return String(output.prefix(1500))
    }

    /// Audio-only mode: system audio + optional mic, no screen capture (outputs .m4a)
    @MainActor
    func startAudioOnlyRecording() async {
        guard !isRecording else { return }

        recordedSystemAudio = true
        recordedMicAudio = micEnabled

        onStatusChange?("Starting audio recording...")

        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())

        // Use .m4a for audio-only
        let prefix = micEnabled ? "Audio_Mix" : "System_Audio"
        outputURL = dir.appendingPathComponent("\(prefix)_\(timestamp).m4a")
        tempMicURL = dir.appendingPathComponent("mic_temp_\(timestamp).caf")

        guard let url = outputURL else { return }
        try? FileManager.default.removeItem(at: url)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                onStatusChange?("No display found")
                return
            }

            // Stream config. Audio-only still requires a valid display configuration.
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.showsCursor = false
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2

            // Writer for audio-only
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            if let writer {
                configureWriterForResilience(writer)
            }

            systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ])
            systemAudioInput?.expectsMediaDataInRealTime = true
            if let ai = systemAudioInput { writer?.add(ai) }

            // Reset state
            sessionStartPTS = nil
            sessionStarted = false
            frameCount = 0

            // Stream - only audio output
            let filter = SCContentFilter(display: display, excludingWindows: [])
            stream = SCStream(filter: filter, configuration: config, delegate: self)
            // We still need screen output to keep the stream alive, but we ignore the frames
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.queue"))
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.queue"))

            // Start microphone if enabled
            if micEnabled {
                startMicrophone()
            }

            // Start writer (session will be started on first sample arrival)
            writer?.startWriting()
            log("Audio-only writer started, status: \(writer?.status.rawValue ?? -1)")

            try await stream?.startCapture()

            beginRecordingActivity()
            isAudioOnlyMode = true
            isRecording = true
            onStatusChange?("Recording audio...")
            onRecordingStateChange?(true)
            log("Audio-only recording started -> \(url.lastPathComponent)")

        } catch let error as NSError {
            log("startAudioOnlyRecording ERROR: domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)")

            // Clean up resources that were started before the failure
            stopMicrophone()
            if let tempURL = tempMicURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            writer?.cancelWriting()
            writer = nil
            systemAudioInput = nil
            stream = nil
            sessionStarted = false
            sessionStartPTS = nil
            recordedSystemAudio = false
            recordedMicAudio = false
            endRecordingActivity()

            onStatusChange?("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func startRecording() async {
        guard !isRecording else {
            log("startRecording: already recording, ignoring")
            return
        }

        log("startRecording CALLED: screen=\(screenEnabled), mic=\(micEnabled), system=\(systemAudioEnabled)")

        // Check what we need to record
        let needScreen = screenEnabled
        let needMic = micEnabled
        let needSystem = systemAudioEnabled
        recordedSystemAudio = needSystem
        recordedMicAudio = needMic

        // Validate: at least one source must be enabled
        if !needScreen && !needMic && !needSystem {
            onStatusChange?("Enable at least one source")
            return
        }

        // Mic-only mode — dictaphone, no SCStream needed
        if needMic && !needScreen && !needSystem {
            log("Entering mic-only mode")
            await startMicOnlyRecording()
            return
        }

        // Audio-only mode (system audio with optional mic, no screen)
        if !needScreen && needSystem {
            log("Entering audio-only mode (system + mic=\(needMic))")
            await startAudioOnlyRecording()
            return
        }

        do {
            onStatusChange?("Requesting permissions...")

            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else {
                onStatusChange?("No display found")
                return
            }

            // Output file
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            outputURL = dir.appendingPathComponent("Recording_\(timestamp).mov")
            tempMicURL = dir.appendingPathComponent("mic_temp_\(timestamp).caf")

            guard let url = outputURL else { return }
            try? FileManager.default.removeItem(at: url)

            let width = Int(display.width)
            let height = Int(display.height)

            // Stream config
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5
            config.showsCursor = true
            config.capturesAudio = systemAudioEnabled
            config.sampleRate = 48000
            config.channelCount = 2

            // Writer
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            if let writer {
                configureWriterForResilience(writer)
            }

            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000
                ]
            ])
            videoInput?.expectsMediaDataInRealTime = true

            // Create pixel buffer adaptor for explicit timing control
            let sourcePixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput!,
                sourcePixelBufferAttributes: sourcePixelBufferAttributes
            )

            if let vi = videoInput { writer?.add(vi) }

            if systemAudioEnabled {
                systemAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128000
                ])
                systemAudioInput?.expectsMediaDataInRealTime = true
                if let ai = systemAudioInput { writer?.add(ai) }
            }

            // Reset state
            sessionStartPTS = nil
            sessionStarted = false
            frameCount = 0

            // Stream
            let filter = SCContentFilter(display: display, excludingWindows: [])
            stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "screen.queue"))
            if systemAudioEnabled {
                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.queue"))
            }

            // Start microphone
            if micEnabled {
                startMicrophone()
            }

            // Start writer (session will be started on first sample arrival)
            writer?.startWriting()
            log("Writer started, status: \(writer?.status.rawValue ?? -1)")

            try await stream?.startCapture()

            beginRecordingActivity()
            isRecording = true
            onStatusChange?("Recording...")
            onRecordingStateChange?(true)

        } catch let error as NSError {
            log("startRecording ERROR: domain=\(error.domain), code=\(error.code), desc=\(error.localizedDescription)")
            log("  flags at error: screen=\(screenEnabled), mic=\(micEnabled), system=\(systemAudioEnabled)")

            // Clean up resources that were started before the failure
            stopMicrophone()
            if let tempURL = tempMicURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            writer?.cancelWriting()
            writer = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            systemAudioInput = nil
            stream = nil
            sessionStarted = false
            sessionStartPTS = nil
            recordedSystemAudio = false
            recordedMicAudio = false
            endRecordingActivity()

            if error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
                onStatusChange?("Permission denied - check System Settings")
            } else {
                onStatusChange?("Error: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    func stopRecording(interrupted: Bool = false) async {
        guard isRecording else { return }

        // Mic-only mode has its own stop
        if isMicOnlyMode {
            await stopMicOnlyRecording()
            return
        }

        let wasAudioOnlyMode = isAudioOnlyMode

        lock.withLock {
            isRecording = false
            isAudioOnlyMode = false
        }

        onStatusChange?(interrupted ? "Recording interrupted. Saving..." : "Stopping...")

        // Stop stream capture first
        if let s = stream {
            do {
                try await s.stopCapture()
                log("Stream stopped successfully")
            } catch {
                log("Stream stop error (ignored): \(error.localizedDescription)")
            }
        }
        stream = nil

        stopMicrophone()

        // Small delay to let pending writes complete
        try? await Task.sleep(nanoseconds: 200_000_000)

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()

        if let w = writer {
            log("Writer status before finish: \(w.status.rawValue)")
            if w.status == .writing {
                await w.finishWriting()
                log("Writer status after finish: \(w.status.rawValue)")
                if w.status != .completed {
                    onStatusChange?("Error: \(w.error?.localizedDescription ?? "unknown")")
                }
            } else {
                onStatusChange?("Writer status: \(w.status.rawValue), error: \(w.error?.localizedDescription ?? "none")")
            }
        }

        let url = outputURL
        let micURL = tempMicURL
        let hadMic = recordedMicAudio
        let hadSystemAudio = recordedSystemAudio
        let hasUsableMic = hasUsableMicRecording(at: micURL)

        lock.withLock {
            writer = nil
            videoInput = nil
            pixelBufferAdaptor = nil
            systemAudioInput = nil
            sessionStarted = false
            sessionStartPTS = nil
        }

        onRecordingStateChange?(false)

        // Mix microphone audio with system audio for audio-only mode
        var finalURL = url
        var keepMicTempForRecovery = false
        if wasAudioOnlyMode, let audioURL = url, let micTempURL = micURL, hadMic, hasUsableMic {
            onStatusChange?("Mixing audio...")
            if let mixed = await mixAudioFiles(systemAudioURL: audioURL, micURL: micTempURL) {
                finalURL = mixed
            } else {
                keepMicTempForRecovery = true
                log("Mix failed; keeping mic temp file for recovery: \(micTempURL.path)")
            }
        }
        // Mix microphone audio with the video if mic was enabled (video mode)
        else if !wasAudioOnlyMode, let videoURL = url, let micTempURL = micURL, hadMic, hasUsableMic {
            onStatusChange?("Mixing audio...")
            if let mixed = await mixMicrophoneAudio(videoURL: videoURL, micURL: micTempURL, hasSystemAudio: hadSystemAudio) {
                finalURL = mixed
            } else {
                keepMicTempForRecovery = true
                log("Mix failed; keeping mic temp file for recovery: \(micTempURL.path)")
            }
        }

        // Cleanup temp mic file
        if let tempURL = micURL {
            if keepMicTempForRecovery {
                log("Mic temp preserved for manual recovery: \(tempURL.path)")
            } else {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        if let url = finalURL {
            if keepMicTempForRecovery {
                onStatusChange?(interrupted ? "Saved with mic backup" : "Saved (mic backup kept)")
            } else {
                onStatusChange?(interrupted ? "Interrupted recording saved!" : "Saved!")
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        recordedSystemAudio = false
        recordedMicAudio = false
        endRecordingActivity()
    }

    private func hasUsableMicRecording(at micURL: URL?) -> Bool {
        guard let micURL else { return false }
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            log("Mic file not found: \(micURL.lastPathComponent)")
            return false
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: micURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        guard size > 1000 else {
            log("Mic file too small: \(size) bytes")
            return false
        }

        return true
    }

    private func assetHasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            return !tracks.isEmpty
        } catch {
            log("Failed to inspect audio tracks for \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Mix two audio files (system audio + mic) into one .m4a
    private func mixAudioFiles(systemAudioURL: URL, micURL: URL) async -> URL? {
        // Check if mic file exists and has content
        guard hasUsableMicRecording(at: micURL) else {
            return nil
        }

        guard let ffmpegURL = ffmpegExecutableURL() else {
            return nil
        }

        let canMixWithSystemAudio = await assetHasAudioTrack(systemAudioURL)

        // Create output path
        let outputURL = systemAudioURL.deletingPathExtension().appendingPathExtension("mixed.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = ffmpegURL
        let errorPipe = Pipe()
        process.standardError = errorPipe

        if canMixWithSystemAudio {
            process.arguments = [
                "-i", systemAudioURL.path,    // Input 1: system audio
                "-i", micURL.path,            // Input 2: microphone audio
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first:dropout_transition=0[aout]",
                "-map", "[aout]",             // Take mixed audio
                "-c:a", "aac",                // Encode audio as AAC
                "-b:a", "192k",
                "-y",                         // Overwrite output
                outputURL.path
            ]
            log("mixAudioFiles: mixing system audio with mic")
        } else {
            process.arguments = [
                "-i", micURL.path,            // Use microphone as the only audio source
                "-map", "0:a:0",
                "-c:a", "aac",
                "-b:a", "192k",
                "-y",
                outputURL.path
            ]
            log("mixAudioFiles: system audio track missing, fallback to mic-only audio")
        }

        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Replace original with mixed version
                try? FileManager.default.removeItem(at: systemAudioURL)
                try? FileManager.default.moveItem(at: outputURL, to: systemAudioURL)
                log("Mixed audio files successfully")
                return systemAudioURL
            } else {
                let ffmpegError = ffmpegFailureOutput(from: process, pipe: errorPipe)
                log("ffmpeg failed with status: \(process.terminationStatus), stderr: \(ffmpegError)")
                try? FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            log("ffmpeg error: \(error)")
            try? FileManager.default.removeItem(at: outputURL)
        }

        return nil
    }

    private func mixMicrophoneAudio(videoURL: URL, micURL: URL, hasSystemAudio: Bool = true) async -> URL? {
        // Check if mic file exists and has content
        guard hasUsableMicRecording(at: micURL) else {
            return nil
        }

        guard let ffmpegURL = ffmpegExecutableURL() else {
            return nil
        }

        let videoContainsAudioTrack = await assetHasAudioTrack(videoURL)
        let canMixWithSystemAudio = hasSystemAudio && videoContainsAudioTrack

        // Create output path
        let outputURL = videoURL.deletingPathExtension().appendingPathExtension("mixed.mov")
        try? FileManager.default.removeItem(at: outputURL)

        let process = Process()
        process.executableURL = ffmpegURL
        let errorPipe = Pipe()
        process.standardError = errorPipe

        if canMixWithSystemAudio {
            // Video has system audio track — mix it with mic via amix
            process.arguments = [
                "-i", videoURL.path,           // Input 1: video with system audio
                "-i", micURL.path,             // Input 2: microphone audio
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first:dropout_transition=0[aout]",
                "-map", "0:v",                 // Take video from first input
                "-map", "[aout]",              // Take mixed audio
                "-c:v", "copy",                // Copy video (no re-encode)
                "-c:a", "aac",                 // Encode audio as AAC
                "-b:a", "192k",
                "-y",                          // Overwrite output
                outputURL.path
            ]
            log("mixMicrophoneAudio: mixing video+system with mic")
        } else {
            if hasSystemAudio {
                log("mixMicrophoneAudio: video has no system audio track, fallback to mic-only audio")
            }
            // Video has no audio track — add mic as the only audio track
            process.arguments = [
                "-i", videoURL.path,           // Input 1: video (no audio track)
                "-i", micURL.path,             // Input 2: microphone audio
                "-map", "0:v:0",               // Take video from first input
                "-map", "1:a:0",               // Take mic audio as-is (no system audio to mix)
                "-c:v", "copy",                // Copy video (no re-encode)
                "-c:a", "aac",                 // Encode audio as AAC
                "-b:a", "192k",
                "-shortest",                   // End output when shortest stream ends
                "-y",                          // Overwrite output
                outputURL.path
            ]
            log("mixMicrophoneAudio: adding mic only (no system audio)")
        }

        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Replace original with mixed version
                try? FileManager.default.removeItem(at: videoURL)
                try? FileManager.default.moveItem(at: outputURL, to: videoURL)
                log("Mixed audio successfully")
                return videoURL
            } else {
                let ffmpegError = ffmpegFailureOutput(from: process, pipe: errorPipe)
                log("ffmpeg failed with status: \(process.terminationStatus), stderr: \(ffmpegError)")
                try? FileManager.default.removeItem(at: outputURL)
            }
        } catch {
            log("ffmpeg error: \(error)")
            try? FileManager.default.removeItem(at: outputURL)
        }

        return nil
    }

    private func startMicrophone() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Create temp file for mic
        if let tempURL = tempMicURL {
            try? FileManager.default.removeItem(at: tempURL)
            micFile = try? AVAudioFile(forWriting: tempURL, settings: format.settings)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Write to file
            try? self?.micFile?.write(from: buffer)

            // Calculate level
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = buffer.frameLength
            var rms: Float = 0
            vDSP_measqv(channelData, 1, &rms, vDSP_Length(frames))
            rms = sqrt(rms)
            let db = 20 * log10(max(rms, 0.00001))
            let level = max(0, min(1, (db + 50) / 50))

            DispatchQueue.main.async {
                self?.onMicLevel?(level)
            }
        }

        do {
            try engine.start()
        } catch {
            print("Mic error: \(error)")
        }
    }

    private func stopMicrophone() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micFile = nil
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        lock.lock()
        let recording = isRecording
        let writerRef = writer
        let videoInputRef = videoInput
        let adaptorRef = pixelBufferAdaptor
        let systemAudioInputRef = systemAudioInput
        let audioOnlyMode = isAudioOnlyMode
        lock.unlock()

        guard recording, let writer = writerRef, writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        switch type {
        case .screen:
            // In audio-only mode, ignore video frames entirely
            if audioOnlyMode {
                // But start session if audio hasn't started it yet
                lock.lock()
                if !sessionStarted {
                    sessionStarted = true
                    sessionStartPTS = pts
                    writerRef?.startSession(atSourceTime: pts)
                    log("Audio-only: session started at video PTS: \(pts.seconds)")
                }
                lock.unlock()
                return
            }

            // Start session on first sample (video or audio, whichever comes first)
            lock.lock()
            if !sessionStarted {
                sessionStarted = true
                sessionStartPTS = pts
                writerRef?.startSession(atSourceTime: pts)
                log("Session started at video PTS: \(pts.seconds)")
            }
            lock.unlock()

            // Append video with original PTS (AVAssetWriter handles offset from session start)
            if let input = videoInputRef, input.isReadyForMoreMediaData,
               let adaptor = adaptorRef,
               let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                adaptor.append(pixelBuffer, withPresentationTime: pts)
            }

            // Preview every 5 frames
            lock.lock()
            frameCount += 1
            let count = frameCount
            lock.unlock()

            if count % 5 == 0 {
                createPreview(from: sampleBuffer)
            }

        case .audio:
            // Start session on first sample if video hasn't started it yet
            lock.lock()
            if !sessionStarted {
                sessionStarted = true
                sessionStartPTS = pts
                writerRef?.startSession(atSourceTime: pts)
                log("Session started at audio PTS: \(pts.seconds)")
            }
            lock.unlock()

            // Append audio directly — no buffer copy/normalization needed
            if let input = systemAudioInputRef, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }

            // System audio level
            calculateSystemAudioLevel(from: sampleBuffer)

        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("SCStream didStopWithError: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStatusChange?("Stream interrupted: saving...")
            if self.isRecording && !self.isMicOnlyMode {
                Task { @MainActor in
                    await self.stopRecording(interrupted: true)
                }
            }
        }
    }

    private func createPreview(from buffer: CMSampleBuffer) {
        guard screenEnabled, let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

        DispatchQueue.main.async { [weak self] in
            self?.onScreenPreview?(nsImage)
        }
    }

    private func calculateSystemAudioLevel(from buffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return }

        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return }

        var rms: Float = 0
        data.withMemoryRebound(to: Float.self, capacity: count) { floatPtr in
            vDSP_measqv(floatPtr, 1, &rms, vDSP_Length(count))
        }
        rms = sqrt(rms)
        let db = 20 * log10(max(rms, 0.00001))
        let level = max(0, min(1, (db + 50) / 50))

        DispatchQueue.main.async { [weak self] in
            self?.onSystemLevel?(level)
        }
    }
}

// MARK: - CMAudioFormatDescription Helper
extension CMAudioFormatDescription {
    static func from(audioFormat: AVAudioFormat) -> CMAudioFormatDescription? {
        var desc: CMAudioFormatDescription?
        let asbd = audioFormat.streamDescription
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        return desc
    }
}

// MARK: - Level Indicator View
class LevelIndicator: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let bgColor = isEnabled ? NSColor.darkGray : NSColor.darkGray.withAlphaComponent(0.3)
        bgColor.setFill()
        bounds.fill()

        if isEnabled && level > 0 {
            let color: NSColor = level > 0.8 ? .systemRed : (level > 0.5 ? .systemYellow : .systemGreen)
            color.setFill()
            NSRect(x: 0, y: 0, width: bounds.width * CGFloat(level), height: bounds.height).fill()
        }
    }
}

// MARK: - Preview View
class PreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        if !isEnabled {
            NSColor(white: 0.1, alpha: 1).setFill()
            bounds.fill()
            let text = "Screen Disabled"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.gray,
                .font: NSFont.systemFont(ofSize: 14)
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            return
        }

        if let img = image {
            let imageAspect = img.size.width / img.size.height
            let viewAspect = bounds.width / bounds.height
            var drawRect = bounds

            if imageAspect > viewAspect {
                let h = bounds.width / imageAspect
                drawRect = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
            } else {
                let w = bounds.height * imageAspect
                drawRect = NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: bounds.height)
            }
            img.draw(in: drawRect)
        } else {
            let text = "No Preview"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.gray,
                .font: NSFont.systemFont(ofSize: 14)
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Main Window
@MainActor
class RecorderWindow: NSWindow {
    let recorder = Recorder()

    var previewView: PreviewView!
    var recordButton: NSButton!
    var timerLabel: NSTextField!
    var statusLabel: NSTextField!

    var screenToggle: NSButton!
    var micToggle: NSButton!
    var systemToggle: NSButton!

    var micLevel: LevelIndicator!
    var systemLevel: LevelIndicator!

    var timer: Timer?
    var startTime: Date?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
                   styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Screen Recorder"
        center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 480))
        content.wantsLayer = true

        // Preview
        previewView = PreviewView(frame: NSRect(x: 20, y: 200, width: 460, height: 260))
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 8
        previewView.layer?.masksToBounds = true
        content.addSubview(previewView)

        // Status & Timer
        statusLabel = NSTextField(labelWithString: "Ready")
        statusLabel.frame = NSRect(x: 20, y: 165, width: 300, height: 20)
        content.addSubview(statusLabel)

        timerLabel = NSTextField(labelWithString: "00:00:00")
        timerLabel.frame = NSRect(x: 380, y: 165, width: 100, height: 20)
        timerLabel.alignment = .right
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        content.addSubview(timerLabel)

        // Toggles
        let toggleY: CGFloat = 125

        screenToggle = NSButton(checkboxWithTitle: "Screen", target: self, action: #selector(toggleScreen))
        screenToggle.frame = NSRect(x: 20, y: toggleY, width: 80, height: 20)
        screenToggle.state = .on
        content.addSubview(screenToggle)

        micToggle = NSButton(checkboxWithTitle: "Microphone", target: self, action: #selector(toggleMic))
        micToggle.frame = NSRect(x: 120, y: toggleY, width: 110, height: 20)
        micToggle.state = .on
        content.addSubview(micToggle)

        systemToggle = NSButton(checkboxWithTitle: "System Audio", target: self, action: #selector(toggleSystem))
        systemToggle.frame = NSRect(x: 250, y: toggleY, width: 120, height: 20)
        systemToggle.state = .on
        content.addSubview(systemToggle)

        // Levels
        let micLabel = NSTextField(labelWithString: "Mic:")
        micLabel.frame = NSRect(x: 20, y: 90, width: 30, height: 16)
        micLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(micLabel)

        micLevel = LevelIndicator(frame: NSRect(x: 55, y: 90, width: 180, height: 16))
        micLevel.wantsLayer = true
        micLevel.layer?.cornerRadius = 3
        content.addSubview(micLevel)

        let sysLabel = NSTextField(labelWithString: "Sys:")
        sysLabel.frame = NSRect(x: 260, y: 90, width: 30, height: 16)
        sysLabel.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(sysLabel)

        systemLevel = LevelIndicator(frame: NSRect(x: 295, y: 90, width: 180, height: 16))
        systemLevel.wantsLayer = true
        systemLevel.layer?.cornerRadius = 3
        content.addSubview(systemLevel)

        // Record button
        recordButton = NSButton(frame: NSRect(x: 20, y: 30, width: 200, height: 44))
        recordButton.title = "Start Recording"
        recordButton.bezelStyle = .rounded
        recordButton.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        content.addSubview(recordButton)

        // Open Recordings folder button
        let openFolderButton = NSButton(frame: NSRect(x: 240, y: 30, width: 240, height: 44))
        openFolderButton.title = "Open Folder"
        openFolderButton.bezelStyle = .rounded
        openFolderButton.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        openFolderButton.target = self
        openFolderButton.action = #selector(openRecordingsFolder)
        content.addSubview(openFolderButton)

        contentView = content

        // Callbacks
        recorder.onScreenPreview = { [weak self] image in
            self?.previewView.image = image
        }

        recorder.onMicLevel = { [weak self] level in
            self?.micLevel.level = level
        }

        recorder.onSystemLevel = { [weak self] level in
            self?.systemLevel.level = level
        }

        recorder.onStatusChange = { [weak self] status in
            self?.statusLabel.stringValue = status
        }

        recorder.onRecordingStateChange = { [weak self] recording in
            self?.updateUI(recording: recording)
        }
    }

    @objc func toggleRecording() {
        if recorder.isRecording {
            Task { await recorder.stopRecording() }
        } else {
            Task { await recorder.startRecording() }
        }
    }

    @objc func openRecordingsFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func toggleScreen() {
        recorder.screenEnabled = screenToggle.state == .on
        previewView.isEnabled = recorder.screenEnabled
    }

    @objc func toggleMic() {
        recorder.micEnabled = micToggle.state == .on
        micLevel.isEnabled = recorder.micEnabled
    }

    @objc func toggleSystem() {
        recorder.systemAudioEnabled = systemToggle.state == .on
        systemLevel.isEnabled = recorder.systemAudioEnabled
    }

    func updateUI(recording: Bool) {
        recordButton.title = recording ? "Stop Recording" : "Start Recording"
        screenToggle.isEnabled = !recording
        micToggle.isEnabled = !recording
        systemToggle.isEnabled = !recording

        if recording {
            startTime = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateTimer()
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            timerLabel.stringValue = "00:00:00"
            previewView.image = nil
            micLevel.level = 0
            systemLevel.level = 0
        }
    }

    func updateTimer() {
        guard let start = startTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        timerLabel.stringValue = String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: RecorderWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = RecorderWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if window.recorder.isRecording {
            Task { @MainActor in
                await window.recorder.stopRecording()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
