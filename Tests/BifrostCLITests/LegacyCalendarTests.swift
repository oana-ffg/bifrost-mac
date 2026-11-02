import Foundation
import XCTest
@testable import BifrostCLI

private final class CountingISO8601DateFormatter: ISO8601DateFormatter, @unchecked Sendable {
    var parseCount = 0
    override func date(from string: String) -> Date? {
        parseCount += 1
        return super.date(from: string)
    }
}

final class LegacyCalendarTests: XCTestCase {
    func testOccurrenceDateMatchesExistingParserAcrossZonesAndDST() throws {
        let timestamps = [
            "2026-10-23T00:00:00+02:00", "2026-10-24T00:00:00+02:00", // All-day boundaries.
            "2026-03-29T01:59:59+01:00", "2026-03-29T03:00:00+02:00", // Spring DST.
            "2026-10-25T02:30:00+02:00", "2026-10-25T02:30:00+01:00", // Repeated fall hour.
            "2026-11-01T01:30:00-04:00", "2026-11-01T01:30:00-05:00",
            "2026-01-02T03:04:05Z", "2026-01-02T03:04:05+00:00",
            "2026-01-02T03:04:05-05:30", "2026-01-02T03:04:05+12:45",
            "2026-01-02T03:04:05+0530"
        ]
        for name in ["GMT", "Europe/Copenhagen", "America/New_York", "Asia/Kathmandu", "Pacific/Chatham"] {
            let zone = try XCTUnwrap(TimeZone(identifier: name))
            let formatter = CountingISO8601DateFormatter(); formatter.timeZone = zone
            let style = Date.ISO8601FormatStyle(timeZone: zone).timeZoneSeparator(.colon)
            for text in timestamps {
                let expected = try XCTUnwrap(formatter.date(from: text), text)
                XCTAssertEqual(LegacyCalendar.occurrenceDate(text, style: style, formatter: formatter), expected, "\(name): \(text)")
            }
            // Exercise canonical strings produced by the bridge throughout the year.
            let start = Date(timeIntervalSince1970: 1767225600)
            formatter.parseCount = 0
            for day in 0..<366 {
                let date = start.addingTimeInterval(Double(day) * 86400)
                let text = formatter.string(from: date)
                XCTAssertEqual(style.format(try style.parse(text)), text)
                XCTAssertEqual(LegacyCalendar.occurrenceDate(text, style: style, formatter: formatter), date)
            }
            XCTAssertEqual(formatter.parseCount, 0, "Canonical bridge timestamps must avoid the legacy parser")
        }
    }

    func testOccurrenceDatePreservesMalformedInputRejectionAndLegacyLeniency() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let formatter = ISO8601DateFormatter(); formatter.timeZone = zone
        let style = Date.ISO8601FormatStyle(timeZone: zone).timeZoneSeparator(.colon)
        let rejected = ["", "invalid", "2026-01-02", "2026-01-02T03:04:05",
                        "2026-01-02T03:04:05.123Z", "2026-13-02T03:04:05Z", "2026-01-32T03:04:05Z",
                        "2026-01-02T25:04:05Z", "2026-01-02T03:60:05Z", "2026-01-02T03:04:60Z",
                        "junk2026-01-02T03:04:05Z", "2026-01-02 03:04:05Z", "2026-01-02t03:04:05z"]
        for text in rejected {
            XCTAssertNil(formatter.date(from: text), text)
            XCTAssertNil(LegacyCalendar.occurrenceDate(text, style: style, formatter: formatter), text)
        }
        // The replacement must not silently tighten inputs the old parser accepted.
        for text in ["2026-01-02T03:04:05Zjunk", " 2026-01-02T03:04:05Z", "2026-01-02T03:04:05Z ",
                     "2026-1-2T3:4:5Z", "2026-02-30T03:04:05Z", "2026-01-02T03:04:05+25:00"] {
            let expected = formatter.date(from: text)
            XCTAssertEqual(LegacyCalendar.occurrenceDate(text, style: style, formatter: formatter), expected, text)
        }
    }
}
