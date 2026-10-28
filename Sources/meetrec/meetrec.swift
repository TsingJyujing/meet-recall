import ArgumentParser
import Foundation

@main
struct Meetrec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record system audio from the current macOS output."
    )

    @Option(
        name: [.customShort("o"), .customLong("output-dir")],
        help: "Directory for recorded data (default: ./recordings)."
    )
    var outputDirectory = "./recordings"

    mutating func run() async throws {
        let path = (outputDirectory as NSString).expandingTildeInPath
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let outputDirectoryURL = URL(
            fileURLWithPath: path,
            relativeTo: workingDirectory
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectoryURL,
            withIntermediateDirectories: true
        )

        let recordingURL = outputDirectoryURL.appendingPathComponent("speaker.m4a")
        guard !FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw ValidationError("Recording already exists: \(recordingURL.path)")
        }

        let recorder = SystemAudioRecorder(outputURL: recordingURL)
        try await recorder.start()
        print("Recording system audio to \(recordingURL.path)")
        print("Press Ctrl+C to stop.")

        await TerminationSignalWaiter().wait()
        try await recorder.stop()
        print("Saved recording to \(recordingURL.path)")
    }
}
