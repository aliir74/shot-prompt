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

    // 8 projects; the default folder is gamma's, so it comes first.
    let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
    var entries: [PickerEntry] {
        pickerEntries(projects: names.map { Project(title: $0.capitalized, root: "/w/x-\($0)") },
                      defaultRoot: "/w/x-gamma")
    }
    var threads: [OpenThread] {
        [OpenThread(id: "1", title: "Fix the picker", project: "app", updatedAt: now.addingTimeInterval(-120)),
         OpenThread(id: "2", title: "Write docs", project: "notes")]
    }

    func rows(threads: [OpenThread]? = nil, detected: String? = "/w/x-eta",
              current: SendTarget = .newThread(root: "/w/x-zeta"), query: String = "") -> [PopupRow] {
        popupRows(threads: threads ?? self.threads, entries: entries, detectedRoot: detected,
                  current: current, query: query, now: now)
    }

    func threadItem(_ t: OpenThread) -> PopupRow {
        .item(PopupItem(target: .thread(id: t.id), title: t.title, detail: threadDetail(t, now: now),
                        toolTip: "\(t.title) · \(t.project)"))
    }

    func projectItem(_ name: String) -> PopupRow {
        .item(PopupItem(target: .newThread(root: "/w/x-\(name)"), title: name.capitalized, detail: "",
                        toolTip: "/w/x-\(name)"))
    }

    // The project names of the item rows, in order.
    func projectNames(_ rows: [PopupRow]) -> [String] {
        rows.compactMap {
            guard case .item(let i) = $0, case .newThread = i.target else { return nil }
            return i.title.lowercased()
        }
    }

    func testPopupRowsUnfiltered() {
        XCTAssertEqual(rows(), [
            .header("Add to an open thread"),
            threadItem(threads[0]),
            threadItem(threads[1]),
            .header("New thread in"),
            projectItem("eta"), projectItem("gamma"), projectItem("zeta"), projectItem("alpha"), projectItem("beta"),
        ])
        XCTAssertEqual(maxPopupProjects, 5)
        if case .item(let i) = rows()[1] { XCTAssertEqual(i.detail, "app · 2m") } else { XCTFail() }
    }

    func testPopupProjectOrder() {
        XCTAssertEqual(projectNames(rows(detected: "/w/x-gamma", current: .thread(id: "1"))),
                       ["gamma", "alpha", "beta", "delta", "epsilon"], "detected == default: still 5 distinct")
        XCTAssertEqual(projectNames(rows(detected: nil, current: .thread(id: "1"))),
                       ["gamma", "alpha", "beta", "delta", "epsilon"], "no detected project: the default leads")
        XCTAssertEqual(projectNames(rows(detected: nil, current: .newThread(root: "/w/x-theta"))),
                       ["gamma", "theta", "alpha", "beta", "delta"], "the current project is listed")
        XCTAssertEqual(projectNames(rows(detected: "/w/x-theta", current: .newThread(root: "/w/x-theta"))),
                       ["theta", "gamma", "alpha", "beta", "delta"])
    }

    func testPopupRowsWithQuery() {
        // Every folder name has "x-", no title or thread does: all 8 projects, in priority order.
        XCTAssertEqual(rows(query: "x-"), [.header("New thread in")] + [
            "eta", "gamma", "zeta", "alpha", "beta", "delta", "epsilon", "theta",
        ].map(projectItem))
        XCTAssertEqual(projectNames(rows(query: "ETA")), ["eta", "zeta", "beta", "theta"])
        XCTAssertEqual(rows(query: "app picker"), [.header("Add to an open thread"), threadItem(threads[0])])
        XCTAssertEqual(rows(query: "notes write"), [.header("Add to an open thread"), threadItem(threads[1])])
        XCTAssertEqual(rows(query: "zzz"), [.header("No match")])
    }

    func testPopupRowsWithoutThreads() {
        XCTAssertEqual(rows(threads: []), [.header("New thread in")]
            + ["eta", "gamma", "zeta", "alpha", "beta"].map(projectItem))
    }

    func testPopupSelection() {
        let r = rows()
        XCTAssertEqual(popupSelection(r, current: .thread(id: "2")), 2)
        XCTAssertEqual(popupSelection(r, current: .newThread(root: "/w/x-gamma")), 5)
        XCTAssertEqual(popupSelection(r, current: nil), 1)
        XCTAssertEqual(popupSelection(r, current: .thread(id: "missing")), 1)
        XCTAssertNil(popupSelection([.header("No match")], current: nil))
    }

    func testMovedSelection() {
        let r = rows()  // headers at 0 and 3, items 1, 2, 4...8
        XCTAssertEqual(movedSelection(r, from: 2, by: 1), 4, "skips the header")
        XCTAssertEqual(movedSelection(r, from: 4, by: -1), 2)
        XCTAssertEqual(movedSelection(r, from: 8, by: 1), 8, "stays at the end")
        XCTAssertEqual(movedSelection(r, from: 1, by: -1), 1, "stays at the start")
        XCTAssertEqual(movedSelection(r, from: nil, by: 1), 1)
        XCTAssertEqual(movedSelection(r, from: 0, by: 1), 1, "from a header: the first item")
        XCTAssertNil(movedSelection([.header("No match")], from: nil, by: 1))
    }

    func testPopupTarget() {
        let r = rows()
        XCTAssertEqual(popupTarget(r, at: 1), .thread(id: "1"))
        XCTAssertEqual(popupTarget(r, at: 4), .newThread(root: "/w/x-eta"))
        XCTAssertNil(popupTarget(r, at: nil))
        XCTAssertNil(popupTarget(r, at: 0))
        XCTAssertNil(popupTarget(r, at: 99))
        XCTAssertNil(popupTarget(r, at: -1))
    }

    func testPopupCommand() {
        XCTAssertEqual(popupCommand("moveUp:"), .up)
        XCTAssertEqual(popupCommand("moveDown:"), .down)
        XCTAssertEqual(popupCommand("insertNewline:"), .pick)
        XCTAssertEqual(popupCommand("cancelOperation:"), .close)
        XCTAssertEqual(popupCommand("insertTab:"), .close)
        XCTAssertEqual(popupCommand("insertBacktab:"), .close)
        XCTAssertEqual(popupCommand("deleteBackward:"), PopupCommand.none)
    }

    func testChipClickToggles() {
        XCTAssertTrue(chipClickToggles(closedAt: nil, now: now))
        XCTAssertTrue(chipClickToggles(closedAt: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(chipClickToggles(closedAt: now.addingTimeInterval(-0.1), now: now),
                       "the click that closed the popup does not open it again")
        XCTAssertEqual(popupReopenGuardSeconds, 0.3)
    }
}
