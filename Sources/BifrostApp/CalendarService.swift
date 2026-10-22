import BifrostCore
import EventKit
import Foundation

final class CalendarService {
    let store = EKEventStore()
    private var previousPermission: String?
    private let lock = NSLock()
    static var permission: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return "authorized"
        case .notDetermined: return "not_requested"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .writeOnly: return "write_only"
        @unknown default: return "unknown"
        }
    }
    private func requirePermission() throws {
        let permission = Self.permission
        if permission != previousPermission { store.reset(); previousPermission = permission }
        guard permission == "authorized" else { throw BridgeError("calendar_permission", "Calendar access is \(Self.permission). Open Bifrost Settings with the CLI settings command and choose Calendar Access. Unattended reads never request permission.") }
    }
    private func calendarRow(_ calendar: EKCalendar) -> [String: Any] {
        ["id": calendar.calendarIdentifier, "name": calendar.title, "source": calendar.source.title, "sourceType": sourceName(calendar.source.sourceType.rawValue)]
    }
    private func sourceName(_ value: Int) -> String {
        [0: "local", 1: "exchange", 2: "calDAV", 3: "mobileMe", 4: "subscribed", 5: "birthdays"][value] ?? "unknown"
    }
    private func availabilityName(_ value: EKEventAvailability) -> String {
        switch value {
        case .notSupported: return "notSupported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "unknown"
        }
    }
    private func statusName(_ value: EKEventStatus) -> String {
        switch value {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }
    private func recurrence(_ event: EKEvent) -> String? {
        guard let rule = event.recurrenceRules?.first else { return nil }
        let frequency: String
        switch rule.frequency {
        case .daily: frequency = "daily"
        case .weekly: frequency = "weekly"
        case .monthly: frequency = "monthly"
        case .yearly: frequency = "yearly"
        @unknown default: frequency = "unknown"
        }
        return rule.interval > 1 ? "\(frequency)×\(rule.interval)" : frequency
    }
    func list() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        try requirePermission()
        return ["calendars": store.calendars(for: .event).map(calendarRow), "freshness": "local_sync_not_verified"]
    }
    func events(_ params: [String: Any]) throws -> [String: Any] {
        let query = try CalendarQuery(params)
        lock.lock(); defer { lock.unlock() }
        try requirePermission()
        let available = store.calendars(for: .event)
        let selected: [EKCalendar]
        if let ids = query.calendarIDs {
            let known = Set(available.map(\.calendarIdentifier))
            guard Set(ids).isSubset(of: known) else { throw BridgeError("unknown_calendar", "A requested calendar identifier is unavailable. Run bifrost calendars to inspect the current identifiers.") }
            selected = available.filter { ids.contains($0.calendarIdentifier) }
        } else { selected = available }
        // Passing nil to EventKit means all calendars; an actually empty selection must remain empty.
        let calendarTimeZone = TimeZone.current
        // EventKit anchors floating all-day dates in the Mac's zone. Include the
        // maximum cross-zone displacement, then filter using projected dates.
        let padding: TimeInterval = query.timeZone == calendarTimeZone ? 0 : 2 * 86400
        let events = selected.isEmpty ? [] : store.events(matching: store.predicateForEvents(withStart: query.start.addingTimeInterval(-padding), end: query.end.addingTimeInterval(padding), calendars: selected))
        guard events.count <= 10_000 else { throw BridgeError("result_limit", "More than 10,000 event occurrences. Use a smaller range.") }
        try requirePermission()
        let formatter = ISO8601DateFormatter(); formatter.timeZone = query.timeZone
        let projected = try events.map { event in
            try CalendarOccurrence(itemID: event.calendarItemIdentifier, seriesID: event.eventIdentifier,
                               calendarID: event.calendar.calendarIdentifier, calendarName: event.calendar.title, title: event.title ?? "",
                               start: event.startDate, end: event.endDate, occurrence: event.occurrenceDate ?? event.startDate,
                               allDay: event.isAllDay, recurring: event.hasRecurrenceRules, recurrence: recurrence(event),
                               availability: availabilityName(event.availability), status: statusName(event.status)).project(timeZone: query.timeZone, calendarTimeZone: calendarTimeZone)
        }
        let rows = projected.filter { $0.overlaps(start: query.start, end: query.end) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return ($0.row["id"] as? String ?? "") < ($1.row["id"] as? String ?? "")
        }.map(\.row)
        return ["start": formatter.string(from: query.start), "end": formatter.string(from: query.end), "events": rows,
                "timezone": query.timeZone.identifier, "calendars": selected.map(calendarRow), "freshness": "local_sync_not_verified"]
    }
}
