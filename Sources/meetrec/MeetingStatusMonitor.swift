import AVFoundation
import AppKit
import CoreAudio
import Darwin
import Dispatch
import Foundation
import Logging

@available(macOS 14.2, *)
struct MeetingStatusMonitor {
    private enum MonitorError: LocalizedError {
        case defaultInputUnavailable
        case processInfoUnavailable
        case chromeScriptUnavailable
        case chromeAutomationFailed(String)

        var errorDescription: String? {
            switch self {
            case .defaultInputUnavailable:
                return "No default microphone input device is available."
            case .processInfoUnavailable:
                return "Could not determine which processes are using the default microphone."
            case .chromeScriptUnavailable:
                return "Could not create the Google Chrome AppleScript."
            case .chromeAutomationFailed(let message):
                return "Could not read Google Chrome tabs. Check its Automation permission. Details: \(message)"
            }
        }
    }

    private static let googleMeetURLPrefix = "https://meet.google.com/meet/"
    private let logger = Logger(label: "meetrec.status-monitor")

    struct RunningProcess: Hashable, Sendable {
        let processID: pid_t
        let name: String
        let executablePath: String?
    }

    struct MicrophoneStatus: Sendable {
        let deviceName: String?
        let isActive: Bool
        let activeProcesses: [RunningProcess]
    }

    enum MeetingTrigger: String, Codable, Sendable {
        case zoom
        case googleChrome = "google_chrome"
    }

    /// Reports activity for the current default input device.
    func microphoneStatus() throws -> MicrophoneStatus {
        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        guard let deviceID = defaultInputDeviceID() else {
            throw MonitorError.defaultInputUnavailable
        }
        guard let processes = activeInputProcesses(using: deviceID) else {
            throw MonitorError.processInfoUnavailable
        }
        return MicrophoneStatus(
            deviceName: deviceName,
            isActive: !processes.isEmpty,
            activeProcesses: processes
        )
    }

    func isInMeeting() throws -> Bool {
        try isInMeeting(using: microphoneStatus())
    }

    func isInMeeting(using status: MicrophoneStatus) throws -> Bool {
        try meetingTrigger(using: status) != nil
    }

    func meetingTrigger(using status: MicrophoneStatus) throws -> MeetingTrigger? {
        guard status.isActive else { return nil }
        if status.activeProcesses.contains(where: { $0.name == "zoom.us" }) {
            return .zoom
        }
        guard status.activeProcesses.contains(where: { $0.name.contains("Google Chrome") }) else {
            return nil
        }
        logger.debug("Chrome is using the microphone; checking its tab URLs.")
        return try hasGoogleMeetURL() ? .googleChrome : nil
    }

    func hasGoogleMeetURL() throws -> Bool {
        logger.debug("Requesting Google Chrome tab URLs.")
        return try chromeTabURLs().contains { $0.hasPrefix(Self.googleMeetURLPrefix) }
    }

    private func chromeTabURLs() throws -> [String] {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).isEmpty else {
            return []
        }

        let source = """
        tell application "Google Chrome"
            set results to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of results to (URL of t)
                end repeat
            end repeat
            return results
        end tell
        """
        let logger = self.logger
        let executeScript = { () throws -> [String] in
            guard let script = NSAppleScript(source: source) else {
                throw MonitorError.chromeScriptUnavailable
            }

            var error: NSDictionary?
            logger.debug("Calling NSAppleScript.executeAndReturnError on main thread.")
            let result = script.executeAndReturnError(&error)
            logger.debug("NSAppleScript.executeAndReturnError returned.")
            if let error {
                throw MonitorError.chromeAutomationFailed(String(describing: error))
            }
            return result.numberOfItems > 0
                ? (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
                : []
        }

        if Thread.isMainThread {
            return try executeScript()
        }
        return try DispatchQueue.main.sync(execute: executeScript)
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private func activeInputProcesses(using deviceID: AudioDeviceID) -> [RunningProcess]? {
        guard let processObjects = readAudioObjectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        ) else {
            return nil
        }

        var activeProcesses: [RunningProcess] = []
        for processObject in processObjects {
            guard let isRunningInput = readUInt32(
                processObject,
                selector: kAudioProcessPropertyIsRunningInput
            ) else {
                return nil
            }
            guard isRunningInput != 0 else { continue }
            guard let devices = readAudioObjectIDs(
                processObject,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ) else {
                return nil
            }
            guard devices.contains(AudioObjectID(deviceID)) else { continue }
            guard let processID = readProcessID(processObject),
                  let process = runningProcess(for: processID)
            else {
                return nil
            }
            activeProcesses.append(process)
        }
        return activeProcesses
    }

    private func readProcessID(_ processObject: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var processID: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &size,
            &processID
        ) == noErr, processID > 0 else {
            return nil
        }
        return processID
    }

    private func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = propertyAddress(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private func readAudioObjectIDs(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID]? {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0
        else {
            return nil
        }
        guard size > 0 else { return [] }

        var objectIDs = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.stride
        )
        let status = objectIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        return Array(objectIDs.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func runningProcess(for processID: pid_t) -> RunningProcess? {
        let path = executablePath(for: processID)
        guard let name = path.map({ URL(fileURLWithPath: $0).lastPathComponent })
                ?? processName(for: processID)
        else {
            return nil
        }
        return RunningProcess(processID: processID, name: name, executablePath: path)
    }

    private func executablePath(for processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return decodeCString(buffer)
    }

    private func processName(for processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_name(processID, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return decodeCString(buffer)
    }

    private func decodeCString(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
