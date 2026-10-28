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
        let microphoneURL = outputDirectoryURL.appendingPathComponent("mic.m4a")
        let existingFiles = [recordingURL, microphoneURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existingFiles.isEmpty else {
            throw ValidationError(
                "Recording already exists: \(existingFiles.map(\.path).joined(separator: ", "))"
            )
        }

        let microphoneRecorder = MicrophoneRecorder(outputURL: microphoneURL)
        try await microphoneRecorder.requestAccess()

        let systemAudioRecorder = SystemAudioRecorder(outputURL: recordingURL)
        try await systemAudioRecorder.start()
        do {
            try microphoneRecorder.start()
        } catch {
            await systemAudioRecorder.cancel()
            throw error
        }

        print("Recording system audio to \(recordingURL.path)")
        print("Recording microphone to \(microphoneURL.path)")
        print("Press Ctrl+C to stop.")

        await TerminationSignalWaiter().wait()

        async let stopSystemAudio: Void = systemAudioRecorder.stop()
        var stopErrors: [String] = []
        do {
            try microphoneRecorder.stop()
        } catch {
            stopErrors.append("microphone: \(error.localizedDescription)")
        }
        do {
            try await stopSystemAudio
        } catch {
            stopErrors.append("system audio: \(error.localizedDescription)")
        }
        guard stopErrors.isEmpty else {
            throw ValidationError("Recording stopped with errors: \(stopErrors.joined(separator: "; "))")
        }

        print("Saved recordings to \(outputDirectoryURL.path)")
    }
}
