import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private enum RecorderError: LocalizedError {
        case noDisplay
        case cannotAddAudioInput
        case noAudioSamples
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                return "ScreenCaptureKit could not find a display for system audio capture."
            case .cannotAddAudioInput:
                return "AVAssetWriter cannot add the AAC audio input."
            case .noAudioSamples:
                return "No system audio samples were captured; no recording was saved."
            case let .writeFailed(message):
                return "Failed to write the system audio recording: \(message)"
            }
        }
    }

    private struct StopState {
        let writer: AVAssetWriter?
        let didStartWriting: Bool
        let writtenBuffers: Int
        let droppedBuffers: Int
        let failure: String?
    }

    private let outputURL: URL
    private let sampleQueue = DispatchQueue(label: "meetrec.system-audio")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var didStartWriting = false
    private var writtenBuffers = 0
    private var droppedBuffers = 0
    private var writeFailure: String?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.cannotAddAudioInput
        }
        writer.add(input)
        self.writer = writer
        audioInput = input

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            try? await stream.stopCapture()
            sampleQueue.sync {
                writer.cancelWriting()
            }
            removeIncompleteOutput()
            throw error
        }
    }

    func stop() async throws {
        guard let stream else { return }
        self.stream = nil

        var captureStopError: Error?
        do {
            try await stream.stopCapture()
        } catch {
            captureStopError = error
        }

        let state = sampleQueue.sync {
            audioInput?.markAsFinished()
            return StopState(
                writer: writer,
                didStartWriting: didStartWriting,
                writtenBuffers: writtenBuffers,
                droppedBuffers: droppedBuffers,
                failure: writeFailure
            )
        }

        guard let writer = state.writer else {
            throw RecorderError.writeFailed("The audio writer was not initialized.")
        }
        if let failure = state.failure {
            writer.cancelWriting()
            removeIncompleteOutput()
            throw RecorderError.writeFailed(failure)
        }
        guard state.didStartWriting, state.writtenBuffers > 0 else {
            writer.cancelWriting()
            removeIncompleteOutput()
            throw RecorderError.noAudioSamples
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            removeIncompleteOutput()
            throw RecorderError.writeFailed(
                writer.error?.localizedDescription ?? "The M4A file could not be finalized."
            )
        }
        if state.droppedBuffers > 0 {
            FileHandle.standardError.write(
                Data("warning: dropped \(state.droppedBuffers) audio buffers while recording.\n".utf8)
            )
        }
        if let captureStopError {
            throw captureStopError
        }
    }

    private func removeIncompleteOutput() {
        guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let writer,
              let audioInput,
              writeFailure == nil
        else {
            return
        }

        if !didStartWriting {
            guard writer.startWriting() else {
                writeFailure = writer.error?.localizedDescription ?? "AVAssetWriter could not start."
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            didStartWriting = true
        }

        guard audioInput.isReadyForMoreMediaData else {
            droppedBuffers += 1
            return
        }
        guard audioInput.append(sampleBuffer) else {
            writeFailure = writer.error?.localizedDescription ?? "AVAssetWriterInput rejected an audio buffer."
            return
        }
        writtenBuffers += 1
    }
}
