import AVFoundation
import AudioToolbox
import Dispatch
import Foundation

final class MicrophoneRecorder: @unchecked Sendable {
    private enum RecorderError: LocalizedError {
        case permissionDenied
        case noInputDevice
        case cannotCreateConverter
        case noAudioSamples
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is denied. Allow it for the terminal app in System Settings → Privacy & Security → Microphone."
            case .noInputDevice:
                return "No microphone input is available."
            case .cannotCreateConverter:
                return "Could not convert microphone audio to the requested sample rate."
            case .noAudioSamples:
                return "No microphone samples were captured; no recording was saved."
            case let .writeFailed(message):
                return "Failed to write the microphone recording: \(message)"
            }
        }
    }

    private let outputURL: URL
    private let sampleRate: Int
    private let errorLock = NSLock()
    private let callbackGroup = DispatchGroup()
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writeFailure: String?
    private var writtenBuffers = 0

    init(outputURL: URL, sampleRate: Int) {
        self.outputURL = outputURL
        self.sampleRate = sampleRate
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
                    AVSampleRateKey: Double(sampleRate),
                    AVNumberOfChannelsKey: Int(format.channelCount),
                    AVEncoderBitRateKey: 128_000,
                ]
            )
        } catch {
            removeIncompleteOutput()
            throw error
        }
        guard let converter = AVAudioConverter(from: format, to: audioFile.processingFormat) else {
            removeIncompleteOutput()
            throw RecorderError.cannotCreateConverter
        }
        self.engine = engine
        self.inputNode = inputNode
        self.audioFile = audioFile
        self.converter = converter
        writeFailure = nil
        writtenBuffers = 0

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

        errorLock.lock()
        let writeFailure = self.writeFailure
        errorLock.unlock()

        if let writeFailure {
            audioFile = nil
            converter = nil
            removeIncompleteOutput()
            throw RecorderError.writeFailed(writeFailure)
        }
        do {
            try flushConverter()
        } catch {
            audioFile = nil
            converter = nil
            removeIncompleteOutput()
            throw error
        }
        guard writtenBuffers > 0 else {
            audioFile = nil
            converter = nil
            removeIncompleteOutput()
            throw RecorderError.noAudioSamples
        }
        audioFile = nil
        converter = nil
    }

    func cancel() {
        inputNode?.removeTap(onBus: 0)
        engine?.stop()
        callbackGroup.wait()
        engine = nil
        inputNode = nil
        audioFile = nil
        converter = nil
        removeIncompleteOutput()
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile, let converter else { return }
        errorLock.lock()
        let hasFailed = writeFailure != nil
        errorLock.unlock()
        guard !hasFailed else { return }

        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 64
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: capacity
        ) else {
            setWriteFailure("Could not allocate a microphone conversion buffer.")
            return
        }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            guard !providedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            setWriteFailure(conversionError?.localizedDescription ?? "AVAudioConverter failed.")
            return
        }
        guard convertedBuffer.frameLength > 0 else { return }

        do {
            try audioFile.write(from: convertedBuffer)
            writtenBuffers += 1
        } catch {
            setWriteFailure(error.localizedDescription)
        }
    }

    private func flushConverter() throws {
        guard let audioFile, let converter,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: 4_096
              )
        else {
            throw RecorderError.cannotCreateConverter
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error else {
            throw RecorderError.writeFailed(
                conversionError?.localizedDescription ?? "AVAudioConverter could not flush microphone audio."
            )
        }
        if outputBuffer.frameLength > 0 {
            try audioFile.write(from: outputBuffer)
            writtenBuffers += 1
        }
    }

    private func setWriteFailure(_ message: String) {
        errorLock.lock()
        if writeFailure == nil {
            writeFailure = message
        }
        errorLock.unlock()
    }

    private func removeIncompleteOutput() {
        guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
