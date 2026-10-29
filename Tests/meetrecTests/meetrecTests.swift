import Logging
import Testing
@testable import meetrec

private enum TestLogging {
    static let logger: Logger = {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        return Logger(label: "meetrec.status-test")
    }()
}

@Test func printCurrentMicrophoneStatus() {
    let logger = TestLogging.logger
    guard #available(macOS 14.2, *) else {
        logger.warning("MeetingStatusMonitor requires macOS 14.2 or later.")
        return
    }

    do {
        let status = try MeetingStatusMonitor().microphoneStatus()
        logger.info("Default microphone: \(status.deviceName ?? "Unknown")")
        logger.info("Microphone active: \(status.isActive)")

        if status.activeProcesses.isEmpty {
            logger.info("No process currently has an active input stream from this microphone.")
        } else {
            for process in status.activeProcesses {
                logger.info(
                    "Process: \(process.name), PID: \(process.processID), path: \(process.executablePath ?? "Unknown")"
                )
            }
        }
    } catch {
        logger.error("Could not read microphone status: \(error.localizedDescription)")
    }
}
