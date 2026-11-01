import Foundation

/// Value-only projection, independent of EventKit and usable in permission-free tests.
public struct CalendarOccurrence {
    public let itemID: String
    public let seriesID: String?
    public let calendarID: String
    public let calendarName: String
    public let title: String
    public let start: Date
    public let end: Date
    public let occurrence: Date
    public let allDay: Bool
    public let recurring: Bool
    public let recurrence: String?
    public let availability: String
    public let status: String

    public init(itemID: String, seriesID: String?, calendarID: String, calendarName: String, title: String, start: Date, end: Date, occurrence: Date, allDay: Bool, recurring: Bool, recurrence: String?, availability: String, status: String) {
        self.itemID = itemID; self.seriesID = seriesID; self.calendarID = calendarID; self.calendarName = calendarName; self.title = title
        self.start = start; self.end = end; self.occurrence = occurrence; self.allDay = allDay; self.recurring = recurring
        self.recurrence = recurrence; self.availability = availability; self.status = status
    }
}

/// Reuse within one request; do not share mutable Foundation formatters across workers.
public final class CalendarOccurrenceProjector {
    private let sourceCalendar: Calendar
    private let outputCalendar: Calendar
    private let formatter: ISO8601DateFormatter
    private let day: DateFormatter
    private let identity: ISO8601DateFormatter

    public convenience init(timeZone: TimeZone, calendarTimeZone: TimeZone) {
        self.init(timeZone: timeZone, calendarTimeZone: calendarTimeZone,
                  makeISOFormatter: { ISO8601DateFormatter() }, makeDayFormatter: { DateFormatter() })
    }

    init(timeZone: TimeZone, calendarTimeZone: TimeZone,
         makeISOFormatter: () -> ISO8601DateFormatter, makeDayFormatter: () -> DateFormatter) {
        var source = Calendar(identifier: .gregorian); source.timeZone = calendarTimeZone
        var output = Calendar(identifier: .gregorian); output.timeZone = timeZone
        sourceCalendar = source; outputCalendar = output
        formatter = makeISOFormatter(); formatter.timeZone = timeZone
        day = makeDayFormatter(); day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        // Occurrence identity must be independent of the output zone.
        identity = makeISOFormatter()
    }

    public func project(_ event: CalendarOccurrence) throws -> CalendarOccurrenceProjection {
        func projected(_ date: Date) throws -> Date {
            guard event.allDay else { return date }
            // All-day events are civil dates, not instants to shift across time zones.
            let components = sourceCalendar.dateComponents([.era, .year, .month, .day], from: date)
            guard let result = outputCalendar.date(from: components),
                  outputCalendar.dateComponents([.era, .year, .month, .day], from: result) == components else {
                throw BridgeError("calendar_date", "An all-day date cannot be represented in the requested time zone.")
            }
            return result
        }
        let calendarEnd: Date
        if event.allDay, event.end != sourceCalendar.startOfDay(for: event.end) {
            // EventKit can return inclusive 23:59:59 ends. Preserve the full
            // final civil day while exposing one consistent exclusive boundary.
            guard let boundary = sourceCalendar.date(byAdding: .day, value: 1, to: sourceCalendar.startOfDay(for: event.end)) else {
                throw BridgeError("calendar_date", "Cannot calculate the all-day event's exclusive end date.")
            }
            calendarEnd = boundary
        } else { calendarEnd = event.end }
        let projectedStart = try projected(event.start), projectedEnd = try projected(calendarEnd)

        let row: [String: Any] = ["id": event.calendarID + "/" + event.itemID + "/" + identity.string(from: event.occurrence),
                "seriesID": event.seriesID as Any? ?? NSNull(), "occurrenceDate": formatter.string(from: try projected(event.occurrence)),
                "calendarID": event.calendarID, "calendar": event.calendarName, "title": event.title,
                "start": formatter.string(from: projectedStart), "end": formatter.string(from: projectedEnd), "startDate": day.string(from: projectedStart),
                "endDateExclusive": event.allDay ? day.string(from: projectedEnd) as Any : NSNull(),
                "isAllDay": event.allDay, "recurring": event.recurring, "recurrence": event.recurrence as Any? ?? NSNull(), "availability": event.availability, "status": event.status]
        return CalendarOccurrenceProjection(start: projectedStart, end: projectedEnd, row: row)
    }
}

public struct CalendarOccurrenceProjection {
    public let start: Date
    public let end: Date
    public let row: [String: Any]

    public init(start: Date, end: Date, row: [String: Any]) {
        self.start = start; self.end = end; self.row = row
    }

    public func overlaps(start rangeStart: Date, end rangeEnd: Date) -> Bool {
        start < rangeEnd && (end > rangeStart || (start == end && start >= rangeStart))
    }
}
