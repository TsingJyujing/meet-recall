import AVFoundation
import Logging
import Testing

@testable import meetrec

enum TestLogging {
    static let logger: Logger = {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        return Logger(label: "meetrec.status-test")
    }()
}

@Test func printCurrentMeetingStatus() {
    let logger = TestLogging.logger
    guard #available(macOS 14.2, *) else {
        logger.warning("MeetingStatusMonitor requires macOS 14.2 or later.")
        return
    }

    let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    guard authorizationStatus == .authorized else {
        let statusDescription: String
        switch authorizationStatus {
        case .notDetermined: statusDescription = "not determined"
        case .restricted: statusDescription = "restricted"
        case .denied: statusDescription = "denied"
        case .authorized: statusDescription = "authorized"
        @unknown default: statusDescription = "unknown"
        }
        logger.warning(
            "Microphone access is \(statusDescription). Allow it for the app running swift test in System Settings → Privacy & Security → Microphone."
        )
        return
    }

    let monitor = MeetingStatusMonitor()
    do {
        let status = try monitor.microphoneStatus()
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
        logger.info("Checking whether a meeting is active.")
        let isInMeeting = try monitor.isInMeeting()
        logger.info("In meeting: \(isInMeeting)")
    } catch {
        logger.error("Could not inspect microphone status: \(error.localizedDescription)")
    }
}
