import AppKit
import BifrostCore
import Foundation

let help = """
Bifrost: a local Mac companion for AI agents.
  bifrost start                         Start /Applications/Bifrost.app independently
  bifrost login enable|disable          Configure start at login
  bifrost status                        Permission and app status (JSON)
  bifrost doctor [--json] [--require calendar,login]
  bifrost apple-calendar [OPTIONS]       Existing Calendar skill compatibility
  bifrost calendars                     List calendar identifiers (JSON)
  bifrost events --start ISO8601 --end ISO8601 [--calendar-id ID ...]
  bifrost automation check BUNDLE_ID     Check app-control permission without prompting
  bifrost permissions request automation BUNDLE_ID
  bifrost permissions request calendar   Explicit interactive Calendar setup
  bifrost mcp                           Stdio MCP adapter for agent hosts
"""
func events(_ args: [String]) throws -> [String: Any] {
    var params: [String: Any] = [:], ids: [String] = []
    var index = 0
    while index < args.count {
        guard index + 1 < args.count else { throw BridgeError("invalid_arguments", "Missing value for \(args[index]).") }
        let option = args[index], value = args[index + 1]
        switch option {
        case "--start", "--end", "--timezone":
            let key = String(option.dropFirst(2))
            guard params[key] == nil else { throw BridgeError("invalid_arguments", "Duplicate \(option).") }; params[key] = value
        case "--calendar-id": ids.append(value)
        default: throw BridgeError("invalid_arguments", "Unknown option: \(option)")
        }
        index += 2
    }
    if !ids.isEmpty { params["calendarIDs"] = ids }
    _ = try CalendarQuery(params)
    return params
}
func start() throws {
    let url = URL(fileURLWithPath: "/Applications/Bifrost.app")
    guard FileManager.default.fileExists(atPath: url.path) else { throw BridgeError("not_installed", "Install Bifrost.app to /Applications first.") }
    do { _ = try BridgeClient.call("status", timeout: 1); try output(["started": true]); return }
    catch { if (error as? BridgeError)?.code == "sandbox_blocked" { throw error } }
    let completed = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var failure: Error?
    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in resultLock.lock(); failure = error; resultLock.unlock(); completed.signal() }
    guard completed.wait(timeout: .now() + 15) == .success else { throw BridgeError("launch_timeout", "LaunchServices did not finish starting Bifrost.") }
    resultLock.lock(); let launchError = failure; resultLock.unlock()
    if let launchError = launchError { throw launchError }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        do { _ = try BridgeClient.call("status", timeout: 1); try output(["started": true]); return }
        catch { if (error as? BridgeError)?.code == "sandbox_blocked" { throw error }; if Date().addingTimeInterval(0.1) >= deadline { throw error }; RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    }
    throw BridgeError("launch_timeout", "Bifrost started but its socket did not become ready.")
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { print(help); exit(0) }
    let rest = Array(args.dropFirst())
    switch command {
    case "help", "--help", "-h": print(help)
    case "start": guard rest.isEmpty else { throw BridgeError("invalid_arguments", "start takes no arguments.") }; try start()
    case "status", "calendars":
        guard rest.isEmpty else { throw BridgeError("invalid_arguments", "This command takes no arguments.") }
        try output(BridgeClient.call(command == "status" ? "status" : "calendar.list"))
    case "apple-calendar": try LegacyCalendar.run(rest)
    case "events": try output(BridgeClient.call("calendar.events", events(rest)))
    case "doctor":
        var requirements = ["calendar"], index = 0
        while index < rest.count {
            if rest[index] == "--json" { index += 1; continue }
            guard rest[index] == "--require", index + 1 < rest.count else { throw BridgeError("invalid_arguments", "Use --require calendar,login and/or --json.") }
            requirements = rest[index + 1].split(separator: ",").map(String.init); index += 2
        }
        let result = try Doctor.run(requirements: requirements); try output(result)
        if result["healthy"] as? Bool != true { exit(2) }
    case "login":
        guard rest.count == 1, ["enable", "disable"].contains(rest[0]) else { throw BridgeError("invalid_arguments", "Use login enable or login disable.") }
        try output(BridgeClient.call("login.set", ["enabled": rest[0] == "enable"]))
    case "automation":
        guard rest.count == 2, rest[0] == "check" else { throw BridgeError("invalid_arguments", "Use automation check BUNDLE_ID.") }
        try output(BridgeClient.call("automation.check", ["target": rest[1]]))
    case "permissions":
        if rest.count == 3, rest[0] == "request", rest[1] == "automation" {
            try output(BridgeClient.call("permissions.request", ["capability": "automation", "target": rest[2]], timeout: 180))
            break
        }
        guard rest == ["request", "calendar"] else { throw BridgeError("invalid_arguments", "Use permissions request calendar.") }
        try output(BridgeClient.call("permissions.request", ["capability": "calendar"], timeout: 125))
    case "mcp": guard rest.isEmpty else { throw BridgeError("invalid_arguments", "mcp takes no arguments.") }; try MCP.run()
    default: throw BridgeError("invalid_arguments", "Unknown command. Run bifrost --help.")
    }
} catch {
    do { try FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8)) }
    catch { exit(74) }
    exit(1)
}
