import AppKit
import Carbon
import BifrostCore

private final class AutomationJob {
    let condition = NSCondition()
    var result: Result<OSStatus, Error>?
}

struct AutomationService {
    private static let lock = NSLock()
    private static var jobs: [String: AutomationJob] = [:]
    private static func determine(target: String, request: Bool) throws -> OSStatus {
        let key = target + (request ? ":request" : ":check")
        lock.lock()
        let job: AutomationJob
        if let existing = jobs[key] { job = existing; lock.unlock() }
        else {
            guard jobs.count < 4 else { lock.unlock(); throw BridgeError("automation_busy", "Four OS Automation checks are pending. Finish any permission prompt before retrying.") }
            job = AutomationJob(); jobs[key] = job; lock.unlock()
            DispatchQueue.global().async {
                let descriptor = NSAppleEventDescriptor(bundleIdentifier: target)
                let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), request)
                job.condition.lock(); job.result = .success(status); job.condition.broadcast(); job.condition.unlock()
                lock.lock(); jobs.removeValue(forKey: key); lock.unlock()
            }
        }
        job.condition.lock(); defer { job.condition.unlock() }
        let deadline = Date().addingTimeInterval(request ? 120 : 3)
        while job.result == nil {
            guard job.condition.wait(until: deadline) else { throw BridgeError("automation_timeout", "macOS has not answered the Automation check. Finish any visible permission prompt. The number of pending OS calls is bounded.") }
        }
        return try job.result!.get()
    }

    static func check(_ params: [String: Any], request: Bool = false) throws -> [String: Any] {
        guard Set(params.keys).isSubset(of: ["target"]), let target = params["target"] as? String,
              target.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw BridgeError("invalid_arguments", "target must be an application bundle identifier.")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: target).isEmpty else {
            throw BridgeError("target_not_running", "Start the target app before checking or requesting Automation permission.")
        }
        let status = try determine(target: target, request: request)
        let state: String
        switch status {
        case noErr: state = "authorized"
        case OSStatus(errAEEventNotPermitted): state = "denied"
        case OSStatus(errAEEventWouldRequireUserConsent): state = "consent_required"
        case OSStatus(procNotFound): state = "target_not_running"
        default: state = "error"
        }
        if request, status != noErr { throw BridgeError("automation_permission", "Automation permission is \(state) (OSStatus \(status)). Review Bifrost in System Settings → Privacy & Security → Automation.") }
        return ["target": target, "state": state, "osStatus": status, "note": "This checks OS permission only; consent_required does not distinguish an unrequested grant from a prior denial. It does not prove the target integration works."]
    }
}
