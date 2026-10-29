import Foundation
import Testing

@testable import meetrec

@Test(.enabled(
    if: ProcessInfo.processInfo.environment["MEETREC_CALENDAR_TEST_JSON_FILE"] != nil,
    "Set MEETREC_CALENDAR_TEST_JSON_FILE to run this calendar test."
))
func printCalendarEventsForSelectedTime() throws {
    let logger = TestLogging.logger
    let iso8601Formatter = ISO8601DateFormatter()
    let queryTime: Date
    if let queryTimeString = ProcessInfo.processInfo.environment["MEETREC_CALENDAR_TEST_TIME"] {
        guard let parsedTime = iso8601Formatter.date(from: queryTimeString) else {
            logger.error("Invalid query time: \(queryTimeString)")
            return
        }
        queryTime = parsedTime
    } else {
        queryTime = Date()
    }

    guard let calendarJSONPath = ProcessInfo.processInfo.environment["MEETREC_CALENDAR_TEST_JSON_FILE"]
    else {
        logger.error("Set MEETREC_CALENDAR_TEST_JSON_FILE to run this calendar test.")
        return
    }

    let calendarJSONURL = URL(fileURLWithPath: calendarJSONPath)
    let calendarJSON = try Data(contentsOf: calendarJSONURL)
    let calendar = try CalendarInfo(jsonData: calendarJSON)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"

    let events = calendar.events(at: queryTime)
    logger.info("Query time: \(iso8601Formatter.string(from: queryTime))")
    logger.info("Matching events: \(events.count)")
    for event in events {
        logger.info("Event: \(event.summary)")
        logger.info(
            "Time: \(formatter.string(from: event.start)) - \(formatter.string(from: event.end))"
        )
        logger.info("Location: \(event.location ?? "Unknown")")
        logger.info("Meeting URL: \(event.meetingURL ?? "Unavailable")")
        logger.info("Calendar URL: \(event.calendarURL ?? "Unavailable")")
    }
}
