import Foundation

struct CalendarEvent: Equatable, Sendable {
    let summary: String
    let start: Date
    let end: Date
    let location: String?
    let description: String?
    let meetingURL: String?
    let calendarURL: String?
}

struct CalendarInfo {
    private struct Export: Decodable {
        let events: EventList
    }

    private struct EventList: Decodable {
        let items: [Event]
    }

    private struct Event: Decodable {
        let summary: String?
        let description: String?
        let location: String?
        let htmlLink: String?
        let hangoutLink: String?
        let status: String?
        let eventType: String?
        let start: EventTime?
        let end: EventTime?
        let attendees: [Attendee]?
        let conferenceData: ConferenceData?
    }

    private struct EventTime: Decodable {
        let dateTime: String?
        let date: String?
    }

    private struct Attendee: Decodable {
        let isSelf: Bool?
        let responseStatus: String?

        enum CodingKeys: String, CodingKey {
            case isSelf = "self"
            case responseStatus
        }
    }

    private struct ConferenceData: Decodable {
        let entryPoints: [EntryPoint]?
    }

    private struct EntryPoint: Decodable {
        let entryPointType: String?
        let uri: String?
    }

    private static let searchOffset: TimeInterval = 5 * 60
    private let calendarEvents: [CalendarEvent]

    init(jsonData: Data) throws {
        let export = try JSONDecoder().decode(Export.self, from: jsonData)
        calendarEvents = export.events.items.compactMap { event in
            guard event.status != "cancelled",
                  event.status != "declined",
                  event.eventType == nil || event.eventType == "default",
                  event.attendees?.contains(where: {
                      $0.isSelf == true && $0.responseStatus == "declined"
                  }) != true,
                  let summary = event.summary,
                  let startTime = event.start,
                  startTime.date == nil,
                  let endTime = event.end,
                  endTime.date == nil,
                  let start = Self.parseDateTime(startTime.dateTime),
                  let end = Self.parseDateTime(endTime.dateTime),
                  start < end
            else {
                return nil
            }

            let videoURL = event.conferenceData?.entryPoints?
                .first(where: { $0.entryPointType == "video" })?.uri
            return CalendarEvent(
                summary: summary,
                start: start,
                end: end,
                location: event.location,
                description: event.description,
                meetingURL: event.hangoutLink ?? videoURL,
                calendarURL: event.htmlLink
            )
        }
    }

    /// Returns every event containing the query time shifted forward by five minutes.
    func events(at date: Date) -> [CalendarEvent] {
        let searchTime = date.addingTimeInterval(Self.searchOffset)
        return calendarEvents
            .filter { $0.start <= searchTime && searchTime < $0.end }
            .sorted { $0.start < $1.start }
    }

    private static func parseDateTime(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
