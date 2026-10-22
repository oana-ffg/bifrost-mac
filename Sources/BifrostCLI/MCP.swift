import BifrostCore
import Foundation

func jsonText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), as: UTF8.self)
}
func output(_ value: Any) throws { try FileHandle.standardOutput.write(contentsOf: Data((try jsonText(value) + "\n").utf8)) }

struct Doctor {
    static func run(requirements: [String]) throws -> [String: Any] {
        guard !requirements.isEmpty, requirements.allSatisfy({ $0 == "calendar" || $0 == "login" }) else { throw BridgeError("invalid_arguments", "Supported required capabilities: calendar, login.") }
        let status = try BridgeClient.call("status") as? [String: Any] ?? [:]
        var problems: [String] = []
        if status["installedPathMatches"] as? Bool != true { problems.append("app_not_running_from_applications") }
        if (status["signing"] as? [String: Any])?["valid"] as? Bool != true { problems.append("invalid_app_signature") }
        if (status["signing"] as? [String: Any])?["team"] as? String == "ad_hoc" { problems.append("unstable_ad_hoc_signing") }
        if requirements.contains("login"), status["loginItem"] as? String != "enabled" { problems.append("login_item_not_enabled") }
        var probe: [String: Any] = [:]
        if requirements.contains("calendar") {
            do {
                let now = Date(), formatter = ISO8601DateFormatter()
                let result = try BridgeClient.call("calendar.events", ["start": formatter.string(from: now.addingTimeInterval(-60)), "end": formatter.string(from: now)]) as? [String: Any] ?? [:]
                if (result["calendars"] as? [Any])?.isEmpty != false { problems.append("no_calendar_coverage") }
                probe = ["ok": true, "calendarCount": (result["calendars"] as? [Any])?.count ?? 0, "eventCount": (result["events"] as? [Any])?.count ?? 0, "freshness": "local_sync_not_verified"]
            } catch { problems.append("calendar_probe_failed"); probe = ["ok": false, "error": error.localizedDescription] }
        }
        return ["healthy": problems.isEmpty, "required": requirements, "problems": problems, "status": status, "calendarProbe": probe]
    }
}

final class Lines {
    private var buffer = Data()
    func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) { guard buffer.distance(from: buffer.startIndex, to: newline) <= Wire.maximumFrame else { throw BridgeError("frame_limit", "MCP input exceeds 8 MiB.") }; let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline); return line }
            guard buffer.count <= Wire.maximumFrame else { throw BridgeError("frame_limit", "MCP input exceeds 8 MiB.") }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw systemError("read stdin") }
            if count == 0 { if buffer.isEmpty { return nil }; throw BridgeError("invalid_request", "MCP messages must end in a newline.") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

struct MCP {
    static let toolNames = ["bifrost_status", "bifrost_doctor", "bifrost_calendars", "bifrost_events"]
    static var tools: [[String: Any]] {
        let descriptions = ["Check the running Mac companion and permission status. Does not request permissions.", "Probe required capabilities for unattended runs. Fails honestly when a source is unavailable.", "List locally synced Calendar identifiers, names and sources. Requires prior Calendar approval.", "Read actual Calendar occurrences in an ISO 8601 range; end is exclusive. Recurrence is expanded. Local sync freshness is not verified."]
        return zip(toolNames, descriptions).map { name, description in
            var properties: [String: Any] = [:], required: [String] = []
            if name == "bifrost_events" { properties = ["start": ["type": "string"], "end": ["type": "string"], "timezone": ["type": "string"], "calendarIDs": ["type": "array", "items": ["type": "string"], "minItems": 1]]; required = ["start", "end"] }
            if name == "bifrost_doctor" { properties = ["require": ["type": "array", "items": ["type": "string", "enum": ["calendar", "login"]]]] }
            return ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false], "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]]
        }
    }
    static func invoke(_ name: String, _ args: [String: Any]) throws -> Any {
        switch name {
        case "bifrost_status", "bifrost_calendars":
            guard args.isEmpty else { throw BridgeError("invalid_arguments", "This tool takes no arguments.") }
            return try BridgeClient.call(name == "bifrost_status" ? "status" : "calendar.list")
        case "bifrost_events": _ = try CalendarQuery(args); return try BridgeClient.call("calendar.events", args)
        case "bifrost_doctor":
            guard Set(args.keys).isSubset(of: ["require"]) else { throw BridgeError("invalid_arguments", "Unknown doctor argument.") }
            if let required = args["require"], !(required is [String]) { throw BridgeError("invalid_arguments", "require must be an array of capability names.") }
            let result = try Doctor.run(requirements: args["require"] as? [String] ?? ["calendar"])
            guard result["healthy"] as? Bool == true else { throw BridgeError("preflight_failed", try jsonText(result)) }
            return result
        default: throw BridgeError("unknown_tool", "Unknown Bifrost tool.")
        }
    }
    static func run() throws {
        let lines = Lines()
        var initialized = false, ready = false
        while let line = try lines.next() {
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            var id: Any = NSNull()
            do {
                let decoded = try JSONSerialization.jsonObject(with: line)
                if let object = decoded as? [String: Any], let requestID = object["id"], requestID is String || requestID is NSNumber { id = requestID }
                guard let request = decoded as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
                    try output(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid JSON-RPC request"]]); continue
                }
                if let requestID = request["id"] { id = requestID }
                let isNotification = request["id"] == nil
                if let params = request["params"], !(params is [String: Any]) {
                    if !isNotification { try output(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "params must be an object"]]) }; continue
                }
                let params = request["params"] as? [String: Any] ?? [:]
                if isNotification { if method == "notifications/initialized", initialized { ready = true }; continue }
                var result: Any
                switch method {
                case "initialize":
                    guard !initialized, let version = params["protocolVersion"] as? String, params["capabilities"] is [String: Any], params["clientInfo"] is [String: Any] else { throw BridgeError("invalid_arguments", "Invalid or duplicate initialization.") }
                    initialized = true
                    let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
                    result = ["protocolVersion": supported.contains(version) ? version : "2025-11-25", "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "bifrost-mac", "version": Wire.appVersion]]
                case "ping": result = [String: Any]()
                case "tools/list":
                    guard ready else { throw BridgeError("not_initialized", "Initialize the MCP session first.") }
                    result = ["tools": tools]
                case "tools/call":
                    guard ready else { throw BridgeError("not_initialized", "Initialize the MCP session first.") }
                    guard let name = params["name"] as? String, toolNames.contains(name), params["arguments"] == nil || params["arguments"] is [String: Any] else { throw BridgeError("invalid_arguments", "Unknown tool or invalid arguments.") }
                    do { result = ["content": [["type": "text", "text": try jsonText(invoke(name, params["arguments"] as? [String: Any] ?? [:]))]], "isError": false] }
                    catch { result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
                default:
                    try output(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]); continue
                }
                try output(["jsonrpc": "2.0", "id": id, "result": result])
            } catch let error as BridgeError {
                try output(["jsonrpc": "2.0", "id": id, "error": ["code": error.code == "not_initialized" ? -32002 : -32602, "message": error.localizedDescription]])
            } catch {
                try output(["jsonrpc": "2.0", "id": id, "error": ["code": -32700, "message": "Invalid JSON"]])
            }
        }
    }
}
