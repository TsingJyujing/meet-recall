import ArgumentParser
import Foundation

@main
struct Meetrec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record audio from meetings."
    )

    @Option(
        name: [.customShort("o"), .customLong("output-dir")],
        help: "Directory for recorded data."
    )
    var outputDirectory = "./recordings"

    mutating func run() throws {
        let path = (outputDirectory as NSString).expandingTildeInPath
        let workingDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let outputURL = URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        print("Output directory: \(outputURL.path)")
        print("Audio recording is not implemented yet.")
    }
}
