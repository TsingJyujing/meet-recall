import Foundation

enum RecordingMetadata {
    private struct Document: Encodable {
        let trigger: String
        let startedAt: Date
        let calendarEvents: [CalendarEvent]?

        private enum CodingKeys: String, CodingKey {
            case trigger
            case startedAt
            case endedAt
            case calendarEvents
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(trigger, forKey: .trigger)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encodeNil(forKey: .endedAt)
            if let calendarEvents {
                try container.encode(calendarEvents, forKey: .calendarEvents)
            } else {
                try container.encodeNil(forKey: .calendarEvents)
            }
        }
    }

    private enum MetadataError: LocalizedError {
        case invalidJSON

        var errorDescription: String? {
            "Recording metadata must contain a JSON object."
        }
    }

    static func createIfMissing(
        at url: URL,
        trigger: MeetingStatusMonitor.MeetingTrigger,
        startedAt: Date,
        calendarEvents: [CalendarEvent]?
    ) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        let document = Document(
            trigger: trigger.rawValue,
            startedAt: startedAt,
            calendarEvents: calendarEvents
        )
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    static func updateEndTime(at url: URL, endedAt: Date) throws {
        let data = try Data(contentsOf: url)
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.invalidJSON
        }
        document["ended_at"] = timestamp(endedAt)
        let updatedData = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedData.write(to: url, options: .atomic)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
