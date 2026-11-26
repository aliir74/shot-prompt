import XCTest
@testable import ShotPromptCore

final class TargetPickerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testParseT3Date() {
        XCTAssertNotNil(parseT3Date("2026-11-26T17:52:59.621Z"))
        XCTAssertNotNil(parseT3Date("2026-11-26T17:52:59Z"))
        XCTAssertEqual(parseT3Date("2026-11-26T17:52:59.621Z")!.timeIntervalSince(parseT3Date("2026-11-26T17:52:59Z")!),
                       0.621, accuracy: 0.001)
        XCTAssertNil(parseT3Date("2026-01-01"))
        XCTAssertNil(parseT3Date(""))
    }

    func ago(_ seconds: TimeInterval) -> String {
        relativeTime(from: now.addingTimeInterval(-seconds), now: now)
    }

    func testRelativeTime() {
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(59), "now")
        XCTAssertEqual(ago(60), "1m")
        XCTAssertEqual(ago(59 * 60 + 59), "59m")
        XCTAssertEqual(ago(3600), "1h")
        XCTAssertEqual(ago(23 * 3600), "23h")
        XCTAssertEqual(ago(24 * 3600), "1d")
        XCTAssertEqual(ago(10 * 86400), "10d")
        XCTAssertEqual(ago(-30), "now", "a time in the future counts as now")
    }

    func testThreadDetail() {
        let t = OpenThread(id: "1", title: "Fix", project: "app", updatedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(threadDetail(t, now: now), "app · 2m")
        XCTAssertEqual(threadDetail(OpenThread(id: "1", title: "Fix", project: "app"), now: now), "app")
    }

    func testMatchesQuery() {
        let fields = ["Fix the picker", "shot-prompt"]
        XCTAssertTrue(matchesQuery("", fields: fields))
        XCTAssertTrue(matchesQuery("  \t ", fields: fields))
        XCTAssertTrue(matchesQuery("shot fix", fields: fields), "words in different fields, any order")
        XCTAssertTrue(matchesQuery("SHOT", fields: fields))
        XCTAssertTrue(matchesQuery("rompt", fields: fields), "anywhere in a word")
        XCTAssertFalse(matchesQuery("shot zzz", fields: fields))
    }
}
