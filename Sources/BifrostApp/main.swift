import AppKit
import BifrostCore
import EventKit
import ServiceManagement
import Security

final class AccessLog {
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    func append(pid: Int32, method: String, success: Bool, count: Int?) {
        lock.lock(); defer { lock.unlock() }
        var entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "pid": pid, "method": method, "success": success]
        if let count = count { entry["count"] = count }
        entries.append(entry); entries = Array(entries.suffix(40))
    }
    func read() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class Service {
    let calendar = CalendarService()
    let access = AccessLog()
    func status() -> [String: Any] {
        var code: SecCode?
        var details: CFDictionary?
        var staticCode: SecStaticCode?
        let signed = SecCodeCopySelf([], &code) == errSecSuccess && code.map { SecCodeCopyStaticCode($0, [], &staticCode) == errSecSuccess } == true && staticCode.map { SecCodeCopySigningInformation($0, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess } == true
        let validSignature = code.map { SecCodeCheckValidity($0, [], nil) == errSecSuccess } == true
        let signing = details as? [String: Any] ?? [:]
        let login: String
        switch SMAppService.mainApp.status {
        case .enabled: login = "enabled"
        case .notRegistered: login = "not_registered"
        case .requiresApproval: login = "requires_approval"
        case .notFound: login = "not_found"
        @unknown default: login = "unknown"
        }
        return ["version": Wire.appVersion, "pid": ProcessInfo.processInfo.processIdentifier,
                "appPath": Bundle.main.bundlePath, "installedPathMatches": Bundle.main.bundlePath == "/Applications/Bifrost.app",
                "calendar": CalendarService.permission, "loginItem": login,
                "signing": ["available": signed, "valid": validSignature, "identifier": signing[kSecCodeInfoIdentifier as String] as? String ?? "unknown", "team": signing[kSecCodeInfoTeamIdentifier as String] as? String ?? "ad_hoc"],
                "freshness": "local_sync_not_verified"]
    }
    func handle(_ method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "status":
            guard params.isEmpty else { throw BridgeError("invalid_arguments", "status takes no arguments.") }
            return status()
        case "calendar.list":
            guard params.isEmpty else { throw BridgeError("invalid_arguments", "calendar.list takes no arguments.") }
            return try calendar.list()
        case "calendar.events": return try calendar.events(params)
        case "login.set":
            guard params.count == 1, let enabled = params["enabled"] as? Bool else { throw BridgeError("invalid_arguments", "enabled must be a boolean.") }
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return status()
        case "automation.check": return try AutomationService.check(params)
        case "permissions.request":
            if params["capability"] as? String == "automation" {
                guard params.count == 2 else { throw BridgeError("invalid_arguments", "Specify capability and target only.") }
                return try AutomationService.check(["target": params["target"] ?? NSNull()], request: true)
            }
            guard params["capability"] as? String == "calendar", params.count == 1 else { throw BridgeError("invalid_arguments", "Specify calendar, or automation with a target bundle identifier.") }
            let done = DispatchSemaphore(value: 0)
            let resultLock = NSLock()
            var outcome: Error?
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.calendar.store.requestFullAccessToEvents { allowed, error in
                    resultLock.lock(); outcome = error ?? (allowed ? nil : BridgeError("calendar_permission", "Calendar access was not granted.")); resultLock.unlock(); done.signal()
                }
            }
            guard done.wait(timeout: .now() + 120) == .success else { throw BridgeError("permission_timeout", "The Calendar permission prompt was not answered. Finish setup in Bifrost.app.") }
            resultLock.lock(); let error = outcome; resultLock.unlock()
            if let error = error { throw error }
            return status()
        default: throw BridgeError("unknown_method", "Unknown bridge method: \(method)")
        }
    }
}

final class Server {
    let listener: Listener
    let service: Service
    private let slots = DispatchSemaphore(value: 16)
    init(service: Service) throws { self.service = service; listener = try Listener() }
    func start() {
        DispatchQueue.global(qos: .utility).async {
            while true {
                do {
                    let client = try self.listener.accept()
                    guard self.slots.wait(timeout: .now()) == .success else {
                        do { try client.send(Wire.failure(BridgeError("busy", "16 requests are already active. Retry later.")), timeout: 1) }
                        catch { NSLog("Bifrost could not report overload: %@", error.localizedDescription) }
                        continue
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { self.slots.signal() }
                        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Answer a local agent request")
                        defer { ProcessInfo.processInfo.endActivity(activity) }
                        var method = "invalid_request"
                        do {
                            let request = try client.receive(timeout: 5)
                            let (name, params) = try Wire.request(request); method = name
                            let result = try self.service.handle(name, params: params)
                            try client.send(Wire.success(result), timeout: 5)
                            let count = (result as? [String: Any])?["events"] as? [Any]
                            self.service.access.append(pid: client.peerPID, method: method, success: true, count: count?.count)
                        } catch {
                            self.service.access.append(pid: client.peerPID, method: method, success: false, count: nil)
                            do { try client.send(Wire.failure(error), timeout: 1) }
                            catch { NSLog("Bifrost response delivery failed for peer %d: %@", client.peerPID, error.localizedDescription) }
                        }
                    }
                } catch { NSLog("Bifrost listener failed: %@", error.localizedDescription); DispatchQueue.main.async { NSApp.terminate(nil) }; return }
            }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let service = Service()
    var server: Server?
    var item: NSStatusItem!
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { server = try Server(service: service); server!.start() }
        catch { alert("Bifrost could not start", error.localizedDescription); NSApp.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Bifrost"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu; rebuild(menu)
    }
    func menuWillOpen(_ menu: NSMenu) { rebuild(menu) }
    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: "Calendar: \(CalendarService.permission)", action: nil, keyEquivalent: ""); status.isEnabled = false; menu.addItem(status)
        add(menu, "Grant Calendar Access…", #selector(grant))
        add(menu, "Grant App Automation…", #selector(automation))
        add(menu, "Health and Recent Access…", #selector(health))
        let enabled = SMAppService.mainApp.status == .enabled
        add(menu, enabled ? "Disable Start at Login" : "Enable Start at Login", #selector(login))
        menu.addItem(.separator()); add(menu, "Quit Bifrost", #selector(quit))
    }
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) { let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; menu.addItem(entry) }
    func alert(_ title: String, _ detail: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; NSApp.activate(ignoringOtherApps: true); alert.runModal() }
    @objc func grant() {
        NSApp.activate(ignoringOtherApps: true)
        service.calendar.store.requestFullAccessToEvents { allowed, error in
            DispatchQueue.main.async { if let error = error { self.alert("Calendar access failed", error.localizedDescription) } else if !allowed { self.alert("Calendar access was not granted", "Allow Bifrost in System Settings → Privacy & Security → Calendars, then run bifrost doctor --require calendar.") } }
        }
    }
    @objc func automation() {
        let dialog = NSAlert(); dialog.messageText = "Grant App Automation"
        dialog.informativeText = "Enter the bundle identifier of an already running app. macOS will ask before granting Bifrost access."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); dialog.accessoryView = field
        dialog.addButton(withTitle: "Request Access"); dialog.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let target = field.stringValue
        DispatchQueue.global().async {
            do { _ = try AutomationService.check(["target": target], request: true) }
            catch { DispatchQueue.main.async { self.alert("Automation setup failed", error.localizedDescription) } }
        }
    }
    @objc func health() {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["health": service.status(), "recentAccess": service.access.read()], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 500)); text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular); text.string = String(decoding: data, as: UTF8.self)
            let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true; scroll.documentView = text; text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            if window == nil { window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window?.title = "Bifrost Health and Recent Access"; window?.isReleasedWhenClosed = false; window?.center() }
            window?.contentView = scroll; window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch { alert("Health display failed", error.localizedDescription) }
    }
    @objc func login() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register(); if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } } }
        catch { alert("Login item change failed", error.localizedDescription) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate(); app.delegate = delegate
app.run()
