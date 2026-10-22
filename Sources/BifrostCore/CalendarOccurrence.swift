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
    public func project(timeZone: TimeZone, calendarTimeZone: TimeZone) throws -> CalendarOccurrenceProjection {
        var sourceCalendar = Calendar(identifier: .gregorian); sourceCalendar.timeZone = calendarTimeZone
        var outputCalendar = Calendar(identifier: .gregorian); outputCalendar.timeZone = timeZone
        func projected(_ date: Date) throws -> Date {
            guard allDay else { return date }
            // All-day events are civil dates, not instants to shift across time zones.
            let components = sourceCalendar.dateComponents([.era, .year, .month, .day], from: date)
            guard let result = outputCalendar.date(from: components),
                  outputCalendar.dateComponents([.era, .year, .month, .day], from: result) == components else {
                throw BridgeError("calendar_date", "An all-day date cannot be represented in the requested time zone.")
            }
            return result
        }
        let calendarEnd: Date
        if allDay, end != sourceCalendar.startOfDay(for: end) {
            // EventKit can return inclusive 23:59:59 ends. Preserve the full
            // final civil day while exposing one consistent exclusive boundary.
            guard let boundary = sourceCalendar.date(byAdding: .day, value: 1, to: sourceCalendar.startOfDay(for: end)) else {
                throw BridgeError("calendar_date", "Cannot calculate the all-day event's exclusive end date.")
            }
            calendarEnd = boundary
        } else { calendarEnd = end }
        let projectedStart = try projected(start), projectedEnd = try projected(calendarEnd)

        let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = Calendar(identifier: .gregorian); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        // Use UTC for the identity so selecting a different output zone doesn't change an occurrence's ID.
        let identity = ISO8601DateFormatter()
        let row: [String: Any] = ["id": calendarID + "/" + itemID + "/" + identity.string(from: occurrence),
                "seriesID": seriesID as Any? ?? NSNull(), "occurrenceDate": formatter.string(from: try projected(occurrence)),
                "calendarID": calendarID, "calendar": calendarName, "title": title,
                "start": formatter.string(from: projectedStart), "end": formatter.string(from: projectedEnd), "startDate": day.string(from: projectedStart),
                "endDateExclusive": allDay ? day.string(from: projectedEnd) as Any : NSNull(),
                "isAllDay": allDay, "recurring": recurring, "recurrence": recurrence as Any? ?? NSNull(), "availability": availability, "status": status]
        return CalendarOccurrenceProjection(start: projectedStart, end: projectedEnd, row: row)
    }
}

public struct CalendarOccurrenceProjection {
    public let start: Date
    public let end: Date
    public let row: [String: Any]

    public func overlaps(start rangeStart: Date, end rangeEnd: Date) -> Bool {
        start < rangeEnd && (end > rangeStart || (start == end && start >= rangeStart))
    }
}
