#!/usr/bin/env python3
"""Count formatter constructions in the real projector, without EventKit.

With an optional Git ref, measure that revision; otherwise measure working source.
Only a temporary source copy is instrumented. No app or bridge is started.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def source(path):
    if len(sys.argv) > 1:
        return subprocess.check_output(["git", "show", f"{sys.argv[1]}:{path}"], text=True)
    return Path(path).read_text()


occurrence = source("Sources/BifrostCore/CalendarOccurrence.swift")
shared = "public final class CalendarOccurrenceProjector" in occurrence
instrumented = occurrence.replace("ISO8601DateFormatter()", "auditISOFormatter()")
instrumented = instrumented.replace("DateFormatter()", "auditDayFormatter()")
setup = 'let projector = CalendarOccurrenceProjector(timeZone: zone, calendarTimeZone: sourceZone)' if shared else ''
projection = 'projector.project(event)' if shared else 'event.project(timeZone: zone, calendarTimeZone: sourceZone)'
runner = '''import Foundation
import CryptoKit
var isoCreations = 0, dayCreations = 0
func auditISOFormatter() -> ISO8601DateFormatter { isoCreations += 1; return ISO8601DateFormatter() }
func auditDayFormatter() -> DateFormatter { dayCreations += 1; return DateFormatter() }
let zone = TimeZone(identifier: "America/New_York")!, sourceZone = TimeZone(identifier: "Europe/Copenhagen")!
let start = Date(timeIntervalSince1970: 1792706400)
var rows: [[String: Any]] = []
let began = ProcessInfo.processInfo.systemUptime
SETUP
for index in 0..<10000 {
    let first = start.addingTimeInterval(Double(index) * 60)
    let event = CalendarOccurrence(itemID: "event-\\(index)", seriesID: "series", calendarID: "calendar", calendarName: "Synthetic", title: "Synthetic", start: first, end: first.addingTimeInterval(3600), occurrence: first, allDay: index % 2 == 0, recurring: true, recurrence: "daily", availability: "busy", status: "confirmed")
    rows.append(try PROJECTION.row)
}
let elapsed = ProcessInfo.processInfo.systemUptime - began
let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
print("rows=\\(rows.count) ISO8601DateFormatter=\\(isoCreations) DateFormatter=\\(dayCreations) seconds=\\(elapsed) sha256=\\(digest)")
'''.replace("SETUP", setup).replace("PROJECTION", projection)

with tempfile.TemporaryDirectory(prefix="bifrost-projection-", dir="/tmp") as directory:
    root = Path(directory)
    (root / "Protocol.swift").write_text(source("Sources/BifrostCore/Protocol.swift"))
    (root / "Occurrence.swift").write_text(instrumented)
    (root / "main.swift").write_text(runner)
    environment = dict(os.environ, HOME=directory, CFFIXED_USER_HOME=directory,
                       CLANG_MODULE_CACHE_PATH=str(root / "cache"))
    subprocess.run(["swiftc", "-O", str(root / "Protocol.swift"), str(root / "Occurrence.swift"),
                    str(root / "main.swift"), "-o", str(root / "measure")], env=environment, check=True)
    subprocess.run([str(root / "measure")], env=environment, check=True)
