import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Logging

@main
struct Meetrec: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Monitor meetings and record system audio and microphone input."
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

    @Option(
        name: .customLong("metrics-port"),
        help: "Serve Prometheus metrics on this localhost port (0 disables the server; default: 0)."
    )
    var metricsPort = 0

    @Option(
        name: .customLong("calendar-file"),
        help: "Google Calendar JSON export (or set MEETREC_CALENDAR_FILE)."
    )
    var calendarFile: String?

    @Option(
        name: .customLong("log-level"),
        help: "Log level: trace, debug, info, notice, warning, error, or critical (default: INFO)."
    )
    var logLevel: LogLevelOption = .info

    enum LogLevelOption: String, ExpressibleByArgument {
        case trace
        case debug
        case info
        case notice
        case warning
        case error
        case critical

        init?(argument: String) {
            self.init(rawValue: argument.lowercased())
        }

        var defaultValueDescription: String { rawValue.uppercased() }

        var loggerLevel: Logger.Level {
            switch self {
            case .trace: return .trace
            case .debug: return .debug
            case .info: return .info
            case .notice: return .notice
            case .warning: return .warning
            case .error: return .error
            case .critical: return .critical
            }
        }
    }

    private enum MonitorEvent: Sendable {
        case poll
        case stop
        case metricsServerEnded
    }

    private struct MonitorEvents: Sendable {
        let stream: AsyncStream<MonitorEvent>
        let continuation: AsyncStream<MonitorEvent>.Continuation
    }

    private enum MetricsServerError: LocalizedError {
        case stoppedUnexpectedly

        var errorDescription: String? {
            "Metrics HTTP server stopped unexpectedly."
        }
    }

    private static let monitorInterval = DispatchTimeInterval.seconds(5)

    mutating func run() async throws {
        let selectedLogLevel = logLevel.loggerLevel
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = selectedLogLevel
            return handler
        }
        let logger = Logger(label: "meetrec")

        guard (8_000...96_000).contains(sampleRate) else {
            throw ValidationError("Sample rate must be between 8000 and 96000 Hz.")
        }
        guard (0...65_535).contains(metricsPort) else {
            throw ValidationError("Metrics port must be between 0 and 65535.")
        }
        try await MicrophoneRecorder.requestAccess()

        let outputDirectoryURL = Self.fileURL(for: outputDirectory)
        let calendarFilePath = calendarFile
            ?? ProcessInfo.processInfo.environment["MEETREC_CALENDAR_FILE"]
        let calendarInfo: CalendarInfo?
        if let calendarFilePath {
            let calendarURL = Self.fileURL(for: calendarFilePath)
            calendarInfo = try CalendarInfo(jsonData: Data(contentsOf: calendarURL))
            logger.info("Calendar lookup enabled with \(calendarURL.path)")
        } else {
            calendarInfo = nil
            logger.info("Calendar lookup is disabled; set MEETREC_CALENDAR_FILE or use --calendar-file.")
        }

        let monitor = MeetingStatusMonitor()
        let metrics = metricsPort == 0 ? nil : MeetrecMetrics()
        let events = Self.monitorEvents()
        let metricsServerTask: Task<Void, Error>?
        if let metrics {
            let application = metrics.application(port: metricsPort, logger: logger)
            logger.info("Starting Prometheus metrics HTTP server on 127.0.0.1:\(metricsPort).")
            metricsServerTask = Task {
                do {
                    try await application.runService(gracefulShutdownSignals: [])
                    guard !Task.isCancelled else { return }
                    events.continuation.yield(.metricsServerEnded)
                    events.continuation.finish()
                } catch is CancellationError {
                    if !Task.isCancelled {
                        events.continuation.yield(.metricsServerEnded)
                        events.continuation.finish()
                    }
                } catch {
                    events.continuation.yield(.metricsServerEnded)
                    events.continuation.finish()
                    throw error
                }
            }
        } else {
            metricsServerTask = nil
        }
        logger.info("Monitoring meeting status every 5 seconds.")

        let initialRecorder = await Self.updateRecordingState(
            monitor: monitor,
            calendarInfo: calendarInfo,
            outputDirectoryURL: outputDirectoryURL,
            sampleRate: sampleRate,
            recorder: nil,
            metrics: metrics,
            logger: logger
        )
        var activeRecorder = initialRecorder
        metrics?.updateRecording(from: false, to: activeRecorder != nil)

        var metricsServerStoppedUnexpectedly = false
        monitorLoop: for await event in events.stream {
            switch event {
            case .stop:
                break monitorLoop
            case .metricsServerEnded:
                metricsServerStoppedUnexpectedly = true
                break monitorLoop
            case .poll:
                break
            }
            let wasRecording = activeRecorder != nil
            activeRecorder = await Self.updateRecordingState(
                monitor: monitor,
                calendarInfo: calendarInfo,
                outputDirectoryURL: outputDirectoryURL,
                sampleRate: sampleRate,
                recorder: activeRecorder,
                metrics: metrics,
                logger: logger
            )
            metrics?.updateRecording(from: wasRecording, to: activeRecorder != nil)
        }

        events.continuation.finish()
        if let activeRecorder {
            await Self.stopRecording(activeRecorder, reason: "monitor stopped", logger: logger)
        }
        if let metricsServerTask {
            if !metricsServerStoppedUnexpectedly {
                metricsServerTask.cancel()
            }
            do {
                try await metricsServerTask.value
                if metricsServerStoppedUnexpectedly {
                    throw MetricsServerError.stoppedUnexpectedly
                }
            } catch is CancellationError {
                if metricsServerStoppedUnexpectedly {
                    throw MetricsServerError.stoppedUnexpectedly
                }
            }
        }
        logger.info("Meeting monitoring stopped.")
    }

    private static func updateRecordingState(
        monitor: MeetingStatusMonitor,
        calendarInfo: CalendarInfo?,
        outputDirectoryURL: URL,
        sampleRate: Int,
        recorder: MeetingRecorder?,
        metrics: MeetrecMetrics?,
        logger: Logger
    ) async -> MeetingRecorder? {
        let isInMeeting: Bool
        do {
            let microphoneStatus = try monitor.microphoneStatus()
            metrics?.updateMicrophone(microphoneStatus.isActive)
            isInMeeting = try monitor.isInMeeting(using: microphoneStatus)
        } catch {
            logger.warning("Could not determine meeting status: \(error.localizedDescription)")
            return recorder
        }
        metrics?.updateMeeting(isInMeeting)

        if isInMeeting {
            guard recorder == nil else { return recorder }

            let recordingStart = Date()
            let matchingEvents = calendarInfo?.events(at: recordingStart) ?? []
            let meeting = matchingEvents.count == 1 ? matchingEvents[0] : nil
            let title = meeting.map { Self.safeFolderTitle($0.summary) } ?? "unknown"
            let folderTime = meeting?.start ?? recordingStart
            let dateDirectory = outputDirectoryURL.appendingPathComponent(
                Self.formatted(recordingStart, as: "yyyy-MM-dd"),
                isDirectory: true
            )
            let sessionDirectory = dateDirectory.appendingPathComponent(
                "\(Self.formatted(folderTime, as: "HHmm"))-\(title)",
                isDirectory: true
            )
            let recordingTime = Self.formatted(recordingStart, as: "HHmmss")
            let speakerURL = sessionDirectory.appendingPathComponent(
                "\(recordingTime)-speaker.m4a"
            )
            let microphoneURL = sessionDirectory.appendingPathComponent(
                "\(recordingTime)-mic.m4a"
            )
            let newRecorder = MeetingRecorder(
                speakerOutputURL: speakerURL,
                microphoneOutputURL: microphoneURL,
                sampleRate: sampleRate
            )

            do {
                try await newRecorder.start()
                logger.info(
                    "Recording started. Speaker: \(speakerURL.path), microphone: \(microphoneURL.path)"
                )
                if calendarInfo != nil, meeting == nil {
                    logger.info(
                        "Calendar lookup matched \(matchingEvents.count) events; using unknown title."
                    )
                }
                return newRecorder
            } catch {
                logger.error("Could not start recording: \(error.localizedDescription)")
                return nil
            }
        }

        guard let recorder else { return nil }
        await stopRecording(recorder, reason: "meeting ended", logger: logger)
        return nil
    }

    private static func stopRecording(
        _ recorder: MeetingRecorder,
        reason: String,
        logger: Logger
    ) async {
        defer { logger.info("Recording ended (\(reason)).") }
        do {
            try await recorder.stop()
        } catch {
            logger.error("Could not stop recording (\(reason)): \(error.localizedDescription)")
        }
    }

    private static func monitorEvents() -> MonitorEvents {
        Darwin.signal(SIGINT, SIG_IGN)
        let (stream, continuation) = AsyncStream<MonitorEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let queue = DispatchQueue(label: "meetrec.monitor-events")
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let timerSource = DispatchSource.makeTimerSource(queue: queue)

        signalSource.setEventHandler {
            _ = continuation.yield(.stop)
            continuation.finish()
        }
        timerSource.schedule(
            deadline: .now() + monitorInterval,
            repeating: monitorInterval
        )
        timerSource.setEventHandler {
            _ = continuation.yield(.poll)
        }

        continuation.onTermination = { _ in
            signalSource.cancel()
            timerSource.cancel()
        }
        signalSource.resume()
        timerSource.resume()

        return MonitorEvents(stream: stream, continuation: continuation)
    }

    private static func fileURL(for path: String) -> URL {
        let expandedPath = (path as NSString).expandingTildeInPath
        let workingDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: expandedPath, relativeTo: workingDirectoryURL)
            .standardizedFileURL
    }

    private static func safeFolderTitle(_ summary: String) -> String {
        let title = summary
            .replacingOccurrences(of: "/", with: "／")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "unknown" : title
    }

    private static func formatted(_ date: Date, as format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
