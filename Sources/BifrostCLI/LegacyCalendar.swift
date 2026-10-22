import Foundation
import BifrostCore

/// Compatibility with the existing apple-calendar skill's arguments and JSON contract.
struct LegacyCalendar {
    static func run(_ arguments: [String]) throws {
        var startText: String?, endText: String?, days: Int?, names: [String] = []
        var zone = TimeZone.current, list = false, index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                print("bifrost apple-calendar [--start YYYY-MM-DD] [--end YYYY-MM-DD | --days N] [--timezone IANA] [--calendar NAME ...] [--list-calendars]"); return
            }
            if argument == "--list-calendars" { list = true; index += 1; continue }
            if ["--start", "--end", "--days", "--timezone", "--calendar"].contains(argument) {
                guard index + 1 < arguments.count else { throw BridgeError("invalid_arguments", "Missing value for \(argument).") }
                let value = arguments[index + 1]
                switch argument {
                case "--start": startText = value
                case "--end": endText = value
                case "--days": guard let count = Int(value), (1...3660).contains(count) else { throw BridgeError("invalid_arguments", "--days must be 1 through 3660.") }; days = count
                case "--timezone": guard let value = TimeZone(identifier: value) else { throw BridgeError("invalid_arguments", "Unknown IANA time zone.") }; zone = value
                case "--calendar": names.append(value)
                default: preconditionFailure("Exhaustive option validation failed")
                }
                index += 2
            } else {
                guard !argument.hasPrefix("-") else { throw BridgeError("invalid_arguments", "Unknown option: \(argument)") }; names.append(argument); index += 1
            }
        }
        guard endText == nil || days == nil else { throw BridgeError("invalid_arguments", "--end and --days are mutually exclusive.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = calendar; day.timeZone = zone; day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        func parse(_ text: String) throws -> Date {
            guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil, let date = day.date(from: text), day.string(from: date) == text else { throw BridgeError("invalid_arguments", "Invalid date; expected YYYY-MM-DD.") }
            return date
        }
        let now = Date(), today = calendar.startOfDay(for: now)
        let start = try startText.map(parse) ?? today
        let inclusiveEnd = try endText.map(parse)
        guard inclusiveEnd == nil || inclusiveEnd! >= start else { throw BridgeError("invalid_range", "--end must be on or after --start.") }
        let end = inclusiveEnd.map { calendar.date(byAdding: .day, value: 1, to: $0)! } ?? calendar.date(byAdding: .day, value: days ?? 2, to: start)!
        guard let length = calendar.dateComponents([.day], from: start, to: end).day, (1...3660).contains(length) else { throw BridgeError("invalid_range", "Use 1 through 3660 days per compatibility query.") }
        let listing = try BridgeClient.call("calendar.list") as? [String: Any] ?? [:]
        let all = listing["calendars"] as? [[String: Any]] ?? []
        let requested = Set(names.map { $0.lowercased() })
        let selected = names.isEmpty ? all : all.filter { requested.contains(($0["name"] as? String ?? "").lowercased()) }
        let found = Set(selected.compactMap { ($0["name"] as? String)?.lowercased() })
        guard requested.isSubset(of: found) else { throw BridgeError("unknown_calendar", "Unknown calendar name. Available: \(all.compactMap { $0["name"] as? String }.sorted().joined(separator: ", "))") }
        let selectedNames = selected.compactMap { $0["name"] as? String }.sorted()
        if list { try output(["calendars": selectedNames]); return }
        let ids = selected.compactMap { $0["id"] as? String }, formatter = ISO8601DateFormatter(); formatter.timeZone = zone
        func rows(_ first: Date, _ last: Date) throws -> [[String: Any]] {
            guard !ids.isEmpty else { throw BridgeError("no_calendar_coverage", "No calendars are available. Verify Calendar setup before reporting an empty agenda.") }
            var records: [String: (Date, [String: Any])] = [:], cursor = first
            while cursor < last {
                let upper = min(calendar.date(byAdding: .day, value: 365, to: cursor)!, last)
                let response = try BridgeClient.call("calendar.events", ["start": formatter.string(from: cursor), "end": formatter.string(from: upper), "calendarIDs": ids, "timezone": zone.identifier]) as? [String: Any] ?? [:]
                for event in response["events"] as? [[String: Any]] ?? [] {
                    guard let id = event["id"] as? String else { throw BridgeError("invalid_response", "Calendar occurrence has no identifier.") }
                    guard let start = event["start"] as? String, let date = formatter.date(from: start) else { throw BridgeError("invalid_response", "Calendar occurrence has an invalid start time.") }
                    records[id] = (date, event)
                }
                cursor = upper
            }
            return records.sorted { left, right in
                left.value.0 == right.value.0 ? left.key < right.key : left.value.0 < right.value.0
            }.map { entry in
                let event = entry.value.1
                return ["calendar": event["calendar"] ?? "", "title": event["title"] ?? "", "start": event["start"] ?? "", "end": event["end"] ?? "", "isAllDay": event["isAllDay"] ?? false, "availability": event["availability"] ?? "unknown", "recurring": event["recurring"] ?? false, "recurrence": event["recurrence"] ?? NSNull(), "status": event["status"] ?? "unknown"]
            }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!, afterTomorrow = calendar.date(byAdding: .day, value: 2, to: today)!
        try output(["timezone": zone.identifier, "now": formatter.string(from: now), "calendars": selectedNames,
                    "range": ["start": day.string(from: start), "end": day.string(from: calendar.date(byAdding: .day, value: -1, to: end)!), "events": try rows(start, end)],
                    "today": try rows(today, tomorrow), "tomorrow": try rows(tomorrow, afterTomorrow)])
    }
}
