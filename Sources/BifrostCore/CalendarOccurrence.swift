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
    public func row(timeZone: TimeZone) -> [String: Any] {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = Calendar(identifier: .gregorian); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        // Use UTC for the identity so selecting a different output zone doesn't change an occurrence's ID.
        let identity = ISO8601DateFormatter()
        return ["id": calendarID + "/" + itemID + "/" + identity.string(from: occurrence),
                "seriesID": seriesID as Any? ?? NSNull(), "occurrenceDate": formatter.string(from: occurrence),
                "calendarID": calendarID, "calendar": calendarName, "title": title,
                "start": formatter.string(from: start), "end": formatter.string(from: end), "startDate": day.string(from: start),
                "endDateExclusive": allDay ? day.string(from: end) as Any : NSNull(),
                "isAllDay": allDay, "recurring": recurring, "recurrence": recurrence as Any? ?? NSNull(), "availability": availability, "status": status]
    }
}
