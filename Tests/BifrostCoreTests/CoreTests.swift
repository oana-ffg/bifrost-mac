import XCTest
import Foundation
import Darwin
@testable import BifrostCore

final class CoreTests: XCTestCase {
    func testRangeValidationAndTimeZones() throws {
        let query = try CalendarQuery(["start": "2026-03-29T00:00:00+01:00", "end": "2026-03-30T00:00:00+02:00"])
        XCTAssertEqual(query.end.timeIntervalSince(query.start), 23 * 3600)
        for params: [String: Any] in [
            ["start": "bad", "end": "2026-01-01T00:00:00Z"],
            ["start": "2026-01-02T00:00:00Z", "end": "2026-01-01T00:00:00Z"],
            ["start": "2026-01-01T00:00:00Z", "end": "2030-01-01T00:00:00Z"],
            ["start": "2026-01-01T00:00:00Z", "end": "2026-01-02T00:00:00Z", "calendarIDs": []],
            ["start": "2026-01-01T00:00:00Z", "end": "2026-01-02T00:00:00Z", "calendarIDs": "all"],
            ["start": "2026-01-01T00:00:00Z", "end": "2026-01-02T00:00:00Z", "unknown": true]
        ] { XCTAssertThrowsError(try CalendarQuery(params)) }
    }
    func testOccurrenceProjectionKeepsAllDayDatesAndSeriesOccurrences() throws {
        let iso = ISO8601DateFormatter(), zone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let first = try XCTUnwrap(iso.date(from: "2026-10-22T22:00:00Z")), end = try XCTUnwrap(iso.date(from: "2026-10-23T22:00:00Z"))
        func value(_ occurrence: Date) -> CalendarOccurrence {
            CalendarOccurrence(itemID: "series", seriesID: "same-series", calendarID: "calendar", calendarName: "Calendar", title: "An event", start: first, end: end, occurrence: occurrence, allDay: true, recurring: true, recurrence: "weekly", availability: "busy", status: "canceled")
        }
        let firstRow = try value(first).project(timeZone: zone, calendarTimeZone: zone).row, next = try value(first.addingTimeInterval(7 * 86400)).project(timeZone: zone, calendarTimeZone: zone).row
        XCTAssertEqual(firstRow["startDate"] as? String, "2026-10-23")
        XCTAssertEqual(firstRow["endDateExclusive"] as? String, "2026-10-24")
        XCTAssertEqual(firstRow["start"] as? String, "2026-10-23T00:00:00+02:00")
        XCTAssertEqual(firstRow["status"] as? String, "canceled")
        XCTAssertNotEqual(firstRow["id"] as? String, next["id"] as? String)
        XCTAssertEqual(firstRow["id"] as? String, try value(first).project(timeZone: TimeZone(secondsFromGMT: 0)!, calendarTimeZone: zone).row["id"] as? String)
    }
    func testAllDayDatesDoNotMoveToThePreviousDayInAnotherZone() throws {
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-10-23T00:00:00+02:00"))
        let end = try XCTUnwrap(iso.date(from: "2026-10-24T00:00:00+02:00"))
        let event = CalendarOccurrence(itemID: "all-day", seriesID: nil, calendarID: "calendar", calendarName: "Calendar", title: "An event", start: start, end: end, occurrence: start, allDay: true, recurring: false, recurrence: nil, availability: "free", status: "confirmed")
        let sourceZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let outputZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let projection = try event.project(timeZone: outputZone, calendarTimeZone: sourceZone)
        let row = projection.row
        XCTAssertFalse(projection.overlaps(start: try XCTUnwrap(iso.date(from: "2026-10-22T00:00:00-04:00")), end: try XCTUnwrap(iso.date(from: "2026-10-23T00:00:00-04:00"))))
        XCTAssertTrue(projection.overlaps(start: try XCTUnwrap(iso.date(from: "2026-10-23T00:00:00-04:00")), end: try XCTUnwrap(iso.date(from: "2026-10-24T00:00:00-04:00"))))
        XCTAssertFalse(projection.overlaps(start: try XCTUnwrap(iso.date(from: "2026-10-24T00:00:00-04:00")), end: try XCTUnwrap(iso.date(from: "2026-10-25T00:00:00-04:00"))))
        XCTAssertEqual(row["startDate"] as? String, "2026-10-23")
        XCTAssertEqual(row["endDateExclusive"] as? String, "2026-10-24")
        XCTAssertEqual(row["start"] as? String, "2026-10-23T00:00:00-04:00")
    }
    func testAllDayProjectionUsesCivilDaysAcrossDaylightSavingAndKeepsTimedInstants() throws {
        let iso = ISO8601DateFormatter()
        let source = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen")), output = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(iso.date(from: "2026-11-01T00:00:00+01:00")), end = try XCTUnwrap(iso.date(from: "2026-11-02T00:00:00+01:00"))
        func event(allDay: Bool) -> CalendarOccurrence {
            CalendarOccurrence(itemID: "event", seriesID: nil, calendarID: "calendar", calendarName: "Calendar", title: "An event", start: start, end: end, occurrence: start, allDay: allDay, recurring: false, recurrence: nil, availability: "free", status: "confirmed")
        }
        let allDay = try event(allDay: true).project(timeZone: output, calendarTimeZone: source)
        XCTAssertEqual(allDay.start, iso.date(from: "2026-11-01T00:00:00-04:00"))
        XCTAssertEqual(allDay.end, iso.date(from: "2026-11-02T00:00:00-05:00"))
        XCTAssertEqual(allDay.end.timeIntervalSince(allDay.start), 25 * 3600)
        let timed = try event(allDay: false).project(timeZone: output, calendarTimeZone: source)
        XCTAssertEqual(timed.start, start); XCTAssertEqual(timed.end, end)
        XCTAssertEqual(timed.row["start"] as? String, "2026-10-31T19:00:00-04:00")
        let point = CalendarOccurrenceProjection(start: start, end: start, row: [:])
        XCTAssertTrue(point.overlaps(start: start, end: end))
        XCTAssertFalse(point.overlaps(start: start.addingTimeInterval(-60), end: start))
    }
    func testInclusiveAllDayEndCoversTheFinalCivilDay() throws {
        let iso = ISO8601DateFormatter()
        let source = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen")), output = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(iso.date(from: "2026-10-23T00:00:00+02:00")), inclusiveEnd = try XCTUnwrap(iso.date(from: "2026-10-23T23:59:59+02:00"))
        let event = CalendarOccurrence(itemID: "event", seriesID: nil, calendarID: "calendar", calendarName: "Calendar", title: "An event", start: start, end: inclusiveEnd, occurrence: start, allDay: true, recurring: false, recurrence: nil, availability: "free", status: "confirmed")
        let value = try event.project(timeZone: output, calendarTimeZone: source)
        XCTAssertEqual(value.row["startDate"] as? String, "2026-10-23")
        XCTAssertEqual(value.row["endDateExclusive"] as? String, "2026-10-24")
        XCTAssertEqual(value.end, iso.date(from: "2026-10-24T00:00:00-04:00"))
        XCTAssertTrue(value.overlaps(start: try XCTUnwrap(iso.date(from: "2026-10-23T23:59:59-04:00")), end: try XCTUnwrap(iso.date(from: "2026-10-24T00:00:00-04:00"))))
        XCTAssertFalse(value.overlaps(start: value.end, end: value.end.addingTimeInterval(60)))
    }
    func testFailureCannotBecomeEmptySuccess() throws {
        XCTAssertThrowsError(try Wire.result(Wire.failure(BridgeError("calendar_permission", "Denied")))) { error in
            XCTAssertEqual((error as? BridgeError)?.code, "calendar_permission")
        }
        XCTAssertThrowsError(try Wire.request(["version": 99, "method": "status"]))
        XCTAssertThrowsError(try Wire.request(["version": 1, "method": "status", "params": []]))
        XCTAssertNotNil(try Wire.result(Wire.success(["events": []])))
    }
    private func temporaryRoot() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/bifrost-tests-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    func testPrivateDirectoryRejectsSymlinkAndOpenPermissions() throws {
        let root = try temporaryRoot()
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try Runtime.checkPrivateDirectory(link, create: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try Runtime.checkPrivateDirectory(root, create: false))
    }
    func testListenerLockAndStaleSocket() throws {
        let root = try temporaryRoot(), path = root.appendingPathComponent("run/bridge.sock").path
        var first: Listener? = try Listener(path: path)
        XCTAssertThrowsError(try Listener(path: path))
        XCTAssertNotNil(first)
        first = nil
        // A stale socket left by a crashed process is safe to replace under the lifetime lock.
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        XCTAssertEqual(bound, 0); Darwin.close(raw)
        let next = try Listener(path: path); XCTAssertGreaterThanOrEqual(next.fd, 0)
    }
    func testForeignFileNeverReplaced() throws {
        let root = try temporaryRoot(), run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = run.appendingPathComponent("bridge.sock")
        try Data("keep me".utf8).write(to: path)
        XCTAssertThrowsError(try Listener(path: path.path))
        XCTAssertEqual(try String(contentsOf: path), "keep me")
    }
    func testConcurrentClientsAndLargeFrames() throws {
        let root = try temporaryRoot(), path = root.appendingPathComponent("run/bridge.sock").path
        let listener = try Listener(path: path), done = expectation(description: "server"), clients = expectation(description: "clients")
        clients.expectedFulfillmentCount = 8
        DispatchQueue.global().async {
            do {
                for _ in 0..<8 {
                    let connection = try listener.accept()
                    DispatchQueue.global().async {
                        do { let request = try connection.receive(timeout: 5); try connection.send(request, timeout: 5) }
                        catch { XCTFail("Server failed: \(error)") }
                    }
                }
            } catch { XCTFail("Accept failed: \(error)") }
            done.fulfill()
        }
        for index in 0..<8 {
            DispatchQueue.global().async {
                do {
                    let connection = try Connection.connect(path: path)
                    XCTAssertEqual(connection.peerPID, getpid())
                    let value: [String: Any] = ["index": index, "payload": String(repeating: "ø", count: 65536)]
                    try connection.send(value, timeout: 5)
                    let result = try connection.receive(timeout: 5)
                    XCTAssertEqual(result["index"] as? Int, index)
                    XCTAssertEqual(result["payload"] as? String, value["payload"] as? String)
                } catch { XCTFail("Client failed: \(error)") }
                clients.fulfill()
            }
        }
        wait(for: [done, clients], timeout: 10)
    }
    func testDisconnectedClientDoesNotStopListener() throws {
        let root = try temporaryRoot(), path = root.appendingPathComponent("run/bridge.sock").path
        let listener = try Listener(path: path)
        var abandoned: Connection? = try Connection.connect(path: path)
        XCTAssertNotNil(abandoned); abandoned = nil
        let accepted = expectation(description: "next client survives")
        DispatchQueue.global().async {
            do { let client = try listener.accept(); try client.send(["alive": true]) }
            catch { XCTFail("Listener failed after abandoned connection: \(error)") }
            accepted.fulfill()
        }
        let next = try Connection.connect(path: path)
        XCTAssertEqual(try next.receive(timeout: 2)["alive"] as? Bool, true)
        wait(for: [accepted], timeout: 3)
    }
    func testPartialFramesOversizeAndDeadline() throws {
        let root = try temporaryRoot(), path = root.appendingPathComponent("run/bridge.sock").path
        let listener = try Listener(path: path)
        let client = try Connection.connect(path: path), accepted = try listener.accept()
        let received = expectation(description: "fragmented")
        DispatchQueue.global().async {
            do { let frame = try accepted.receive(timeout: 2); XCTAssertEqual(frame["value"] as? String, "ok") }
            catch { XCTFail("Fragmented receive failed: \(error)") }
            received.fulfill()
        }
        let payload = Data("{\"value\":\"ok\"}".utf8)
        var count = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &count) { Data($0) }; framed.append(payload)
        for byte in framed { var byte = byte; XCTAssertEqual(Darwin.write(client.fd, &byte, 1), 1) }
        wait(for: [received], timeout: 3)
        var oversized = UInt32(Wire.maximumFrame + 1).bigEndian
        XCTAssertEqual(withUnsafeBytes(of: &oversized) { Darwin.write(client.fd, $0.baseAddress, 4) }, 4)
        XCTAssertThrowsError(try accepted.receive(timeout: 1)) { XCTAssertEqual(($0 as? BridgeError)?.code, "frame_limit") }
        XCTAssertThrowsError(try accepted.receive(timeout: 0.05)) { XCTAssertEqual(($0 as? BridgeError)?.code, "deadline_exceeded") }
    }
}
