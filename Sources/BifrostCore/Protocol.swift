import Foundation

public struct BridgeError: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code): \(message)" }
}

public enum Wire {
    public static let version = 1
    public static let maximumFrame = 8 * 1024 * 1024
    public static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unbundled" }
    public static func success(_ result: Any) -> [String: Any] { ["version": version, "ok": true, "result": result] }
    public static func failure(_ error: Error) -> [String: Any] {
        let failure = error as? BridgeError ?? BridgeError("internal_error", error.localizedDescription)
        return ["version": version, "ok": false, "error": ["code": failure.code, "message": failure.message]]
    }
    public static func result(_ reply: [String: Any]) throws -> Any {
        guard reply["version"] as? Int == version else { throw BridgeError("protocol_version", "Update the CLI and installed Bifrost.app together.") }
        guard reply["ok"] as? Bool == true, let result = reply["result"] else {
            let error = reply["error"] as? [String: Any] ?? [:]
            throw BridgeError(error["code"] as? String ?? "invalid_response", error["message"] as? String ?? "Invalid bridge response.")
        }
        return result
    }
    public static func request(_ value: [String: Any]) throws -> (String, [String: Any]) {
        guard value["version"] as? Int == version else { throw BridgeError("protocol_version", "Supported local protocol version is 1.") }
        guard let method = value["method"] as? String, !method.isEmpty, method.utf8.count <= 128 else { throw BridgeError("invalid_request", "A method string is required.") }
        if let params = value["params"], !(params is [String: Any]) { throw BridgeError("invalid_request", "params must be an object.") }
        return (method, value["params"] as? [String: Any] ?? [:])
    }
}

public struct CalendarQuery {
    public let start: Date
    public let end: Date
    public let calendarIDs: [String]?
    public let timeZone: TimeZone
    public init(_ params: [String: Any]) throws {
        guard Set(params.keys).isSubset(of: ["start", "end", "calendarIDs", "timezone"]) else { throw BridgeError("invalid_arguments", "Unknown Calendar query parameter.") }
        func date(_ key: String) throws -> Date {
            guard let text = params[key] as? String else { throw BridgeError("invalid_arguments", "\(key) must be an ISO 8601 timestamp with time zone.") }
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            guard let date = plain.date(from: text) ?? fractional.date(from: text) else { throw BridgeError("invalid_arguments", "Invalid \(key) timestamp.") }
            return date
        }
        if let value = params["timezone"] {
            guard let name = value as? String, let zone = TimeZone(identifier: name) else { throw BridgeError("invalid_arguments", "timezone must be a valid IANA time zone.") }
            timeZone = zone
        } else { timeZone = .current }
        start = try date("start"); end = try date("end")
        guard end > start, end.timeIntervalSince(start) <= 366 * 86400 else { throw BridgeError("invalid_range", "Use an end after start, with at most 366 days per query.") }
        if let ids = params["calendarIDs"] {
            guard let values = ids as? [String], !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else { throw BridgeError("invalid_arguments", "calendarIDs must be a nonempty array of nonempty identifiers, or omitted.") }
            calendarIDs = values
        } else { calendarIDs = nil }
    }
}
