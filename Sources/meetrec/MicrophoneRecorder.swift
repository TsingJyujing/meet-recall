import AVFoundation
import AudioToolbox
import Dispatch
import Foundation

final class MicrophoneRecorder: @unchecked Sendable {
    private enum RecorderError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is denied. Allow it for the terminal app in System Settings → Privacy & Security → Microphone."
            case .noInputDevice:
                return "No microphone input is available."
            case let .writeFailed(message):
                return "Failed to write the microphone recording: \(message)"
            }
        }
    }

    private let outputURL: URL
    private let errorLock = NSLock()
    private let callbackGroup = DispatchGroup()
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var writeFailure: String?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func requestAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            guard granted else { throw RecorderError.permissionDenied }
        case .denied, .restricted:
            throw RecorderError.permissionDenied
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderBitRateKey: 128_000,
                ]
            )
        } catch {
            removeIncompleteOutput()
            throw error
        }
        self.engine = engine
        self.inputNode = inputNode
        self.audioFile = audioFile
        writeFailure = nil

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.callbackGroup.enter()
            defer { self.callbackGroup.leave() }
            self.write(buffer)
        }

        do {
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    func stop() throws {
        guard let engine else { return }
        inputNode?.removeTap(onBus: 0)
        engine.stop()
        callbackGroup.wait()
        self.engine = nil
        inputNode = nil
        audioFile = nil

        errorLock.lock()
        let writeFailure = self.writeFailure
        errorLock.unlock()

        if let writeFailure {
            removeIncompleteOutput()
            throw RecorderError.writeFailed(writeFailure)
        }
    }

    func cancel() {
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        callbackGroup.wait()
        engine = nil
        inputNode = nil
        audioFile = nil
        removeIncompleteOutput()
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile else { return }
        do {
            try audioFile.write(from: buffer)
        } catch {
            errorLock.lock()
            if writeFailure == nil {
                writeFailure = error.localizedDescription
            }
            errorLock.unlock()
        }
    }

    private func removeIncompleteOutput() {
        guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
