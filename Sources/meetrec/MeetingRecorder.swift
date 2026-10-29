import Foundation
import Logging

/// Coordinates system-audio and microphone capture into separate M4A files.
/// Keep a strong reference to the recorder until `stop()` completes.
actor MeetingRecorder {
    private enum State {
        case idle
        case starting
        case recording
        case stopping
        case stopped
    }

    private enum RecorderError: LocalizedError {
        case invalidState(String)
        case invalidSampleRate(Int)
        case outputPathsMustBeDifferent
        case outputMustBeM4A(String)
        case existingFiles([String])
        case stopFailed([String])

        var errorDescription: String? {
            switch self {
            case .invalidState(let message):
                return message
            case .invalidSampleRate(let sampleRate):
                return "Sample rate must be between 8000 and 96000 Hz; got \(sampleRate)."
            case .outputPathsMustBeDifferent:
                return "Speaker and microphone recordings must use different output paths."
            case .outputMustBeM4A(let path):
                return "Recording output must use the .m4a extension: \(path)"
            case .existingFiles(let paths):
                return "Refusing to overwrite existing recordings: \(paths.joined(separator: ", "))"
            case .stopFailed(let errors):
                return "Failed to finalize recordings: \(errors.joined(separator: "; "))"
            }
        }
    }

    private let speakerOutputURL: URL
    private let microphoneOutputURL: URL
    private let sampleRate: Int
    private let systemAudioRecorder: SystemAudioRecorder
    private let microphoneRecorder: MicrophoneRecorder
    private let logger = Logger(label: "meetrec.recorder")
    private var state = State.idle

    init(
        speakerOutputURL: URL,
        microphoneOutputURL: URL,
        sampleRate: Int = 48_000
    ) {
        self.speakerOutputURL = speakerOutputURL.standardizedFileURL
        self.microphoneOutputURL = microphoneOutputURL.standardizedFileURL
        self.sampleRate = sampleRate
        systemAudioRecorder = SystemAudioRecorder(
            outputURL: self.speakerOutputURL,
            sampleRate: sampleRate
        )
        microphoneRecorder = MicrophoneRecorder(
            outputURL: self.microphoneOutputURL,
            sampleRate: sampleRate
        )
    }

    /// Starts both captures and returns once they are running in the background.
    func start() async throws {
        guard case .idle = state else {
            throw RecorderError.invalidState("A MeetingRecorder can only be started once.")
        }
        state = .starting

        do {
            try prepareOutputPaths()
        } catch {
            state = .idle
            throw error
        }

        do {
            try await microphoneRecorder.requestAccess()
            let microphoneName = microphoneRecorder.defaultInputDeviceName() ?? "Unknown"
            logger.info("Using microphone: \(microphoneName)")
            try await systemAudioRecorder.start()
            try microphoneRecorder.start()
            state = .recording
        } catch {
            microphoneRecorder.cancel()
            await systemAudioRecorder.cancel()
            state = .idle
            throw error
        }
    }

    /// Stops both captures and finalizes their output files.
    func stop() async throws {
        switch state {
        case .recording:
            state = .stopping
        case .stopped:
            return
        case .idle:
            throw RecorderError.invalidState("start() must succeed before stop() is called.")
        case .starting:
            throw RecorderError.invalidState("Recording startup is still in progress.")
        case .stopping:
            throw RecorderError.invalidState("Recording shutdown is already in progress.")
        }

        async let stopSystemAudio: Void = systemAudioRecorder.stop()
        var errors: [String] = []
        do {
            try microphoneRecorder.stop()
        } catch {
            errors.append("microphone: \(error.localizedDescription)")
        }
        do {
            try await stopSystemAudio
        } catch {
            errors.append("system audio: \(error.localizedDescription)")
        }

        state = .stopped
        if !errors.isEmpty {
            throw RecorderError.stopFailed(errors)
        }
    }

    private func prepareOutputPaths() throws {
        guard (8_000...96_000).contains(sampleRate) else {
            throw RecorderError.invalidSampleRate(sampleRate)
        }
        guard speakerOutputURL.path != microphoneOutputURL.path else {
            throw RecorderError.outputPathsMustBeDifferent
        }
        for url in [speakerOutputURL, microphoneOutputURL] {
            guard url.pathExtension.lowercased() == "m4a" else {
                throw RecorderError.outputMustBeM4A(url.path)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let existingFiles = [speakerOutputURL, microphoneOutputURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        guard existingFiles.isEmpty else {
            throw RecorderError.existingFiles(existingFiles)
        }
    }
}
