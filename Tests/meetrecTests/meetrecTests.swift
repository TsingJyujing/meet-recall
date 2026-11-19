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
        let trigger = try monitor.meetingTrigger(using: status, detectTab: false)
        logger.info("In meeting (microphone-only detection): \(trigger != nil)")
    } catch {
        logger.error("Could not inspect microphone status: \(error.localizedDescription)")
    }
}

@Test func microphoneActivityRequiresAllowedProcess() throws {
    guard #available(macOS 14.2, *) else { return }

    let monitor = MeetingStatusMonitor()
    let activeStatus = MeetingStatusMonitor.MicrophoneStatus(
        deviceName: "Test microphone",
        isActive: true,
        activeProcesses: [
            MeetingStatusMonitor.RunningProcess(
                processID: 123,
                name: "Google Chrome Helper",
                executablePath: nil
            )
        ]
    )
    let unrelatedStatus = MeetingStatusMonitor.MicrophoneStatus(
        deviceName: "Test microphone",
        isActive: true,
        activeProcesses: [
            MeetingStatusMonitor.RunningProcess(
                processID: 456,
                name: "Some other app",
                executablePath: nil
            )
        ]
    )
    let inactiveStatus = MeetingStatusMonitor.MicrophoneStatus(
        deviceName: "Test microphone",
        isActive: false,
        activeProcesses: []
    )

    let activeTrigger = try monitor.meetingTrigger(using: activeStatus, detectTab: false)
    let unrelatedTrigger = try monitor.meetingTrigger(using: unrelatedStatus, detectTab: false)
    let inactiveTrigger = try monitor.meetingTrigger(using: inactiveStatus, detectTab: false)

    #expect(activeTrigger?.rawValue == "google_chrome")
    #expect(unrelatedTrigger == nil)
    #expect(inactiveTrigger == nil)
}
