import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Logging

@main
struct Meetrec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record system audio and microphone input."
    )

    @Option(
        name: [.customShort("o"), .customLong("output-dir")],
        help: "Directory for recorded data (default: ./recordings)."
    )
    var outputDirectory = "./recordings"

    @Option(
        name: .customLong("sample-rate"),
        help: "Shared sample rate in Hz for both files (8000–96000, default: 48000)."
    )
    var sampleRate = 48_000

    mutating func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "meetrec")

        let path = (outputDirectory as NSString).expandingTildeInPath
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let outputDirectoryURL = URL(
            fileURLWithPath: path,
            relativeTo: workingDirectory
        ).standardizedFileURL
        let speakerURL = outputDirectoryURL.appendingPathComponent("speaker.m4a")
        let microphoneURL = outputDirectoryURL.appendingPathComponent("mic.m4a")
        let recorder = MeetingRecorder(
            speakerOutputURL: speakerURL,
            microphoneOutputURL: microphoneURL,
            sampleRate: sampleRate
        )
        try await recorder.start()

        logger.info("Recording system audio to \(speakerURL.path)")
        logger.info("Recording microphone to \(microphoneURL.path)")
        logger.info("Press Ctrl+C to stop.")

        await Self.waitForCtrlC()
        try await recorder.stop()

        logger.info("Saved recordings to \(outputDirectoryURL.path)")
    }

    private static func waitForCtrlC() async {
        Darwin.signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
    }
}
