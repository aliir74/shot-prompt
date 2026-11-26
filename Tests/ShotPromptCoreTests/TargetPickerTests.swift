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
            .addFolder,
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
        ].map(projectItem) + [.addFolder])
        XCTAssertEqual(projectNames(rows(query: "ETA")), ["eta", "zeta", "beta", "theta"])
        XCTAssertEqual(rows(query: "app picker"),
                       [.header("Add to an open thread"), threadItem(threads[0]), .addFolder])
        XCTAssertEqual(rows(query: "notes write"),
                       [.header("Add to an open thread"), threadItem(threads[1]), .addFolder])
        XCTAssertEqual(rows(query: "zzz"), [.header("No match"), .addFolder], "a folder can still be added")
    }

    func testPopupRowsWithoutThreads() {
        XCTAssertEqual(rows(threads: []), [.header("New thread in")]
            + ["eta", "gamma", "zeta", "alpha", "beta"].map(projectItem) + [.addFolder])
    }

    func testPopupRowsForOtherTargets() {
        // Codex cannot add to a thread, so pickerThreads gives it none: projects only.
        let codex = pickerThreads(app: .codex) { threads }
        XCTAssertEqual(popupRows(threads: codex, entries: entries, detectedRoot: "/w/x-eta",
                                 current: .newThread(root: "/w/x-zeta"), query: "", now: now, app: .codex),
                       [.header("Start Codex in")] + ["eta", "gamma", "zeta", "alpha", "beta"].map(projectItem)
                           + [.addFolder])
        XCTAssertEqual(projectsHeader(app: .command), "New thread in")
        XCTAssertEqual(projectsHeader(app: .claudeCode), "Start Claude Code in")
        XCTAssertEqual(popupPlaceholder(app: .command), "Search threads and projects")
        XCTAssertEqual(popupPlaceholder(app: .cursorAgent), "Search projects")
    }

    func testPickerThreadsOnlyForTheCommand() {
        var loads = 0
        func load() -> [OpenThread] { loads += 1; return threads }
        XCTAssertEqual(pickerThreads(app: .command, load: load), threads)
        XCTAssertEqual(loads, 1)
        for app in Target.allCases where app != .command {
            XCTAssertEqual(pickerThreads(app: app, load: load), [], app.title)
        }
        XCTAssertEqual(loads, 1, "T3's database is not read for other targets")
        XCTAssertTrue(Target.command.addsToThreads)
        XCTAssertFalse(Target.claudeCode.addsToThreads)
    }

    func testRememberedThreadFallsBackForOtherTargets() {
        let last = LastTarget(target: .thread(id: "1"), at: now.addingTimeInterval(-60))
        let codexThreads = pickerThreads(app: .codex) { threads }
        let remembered = rememberedTarget(last, minutes: 15, now: now, threads: codexThreads, entries: entries)
        XCTAssertNil(remembered)
        XCTAssertEqual(resolveTarget(picked: nil, remembered: remembered, detectedRoot: "/w/x-eta",
                                     entries: entries, defaultRoot: "/w/default"),
                       .newThread(root: "/w/x-eta"), "the project, not the thread")
        let t3Threads = pickerThreads(app: .command) { threads }
        XCTAssertEqual(rememberedTarget(last, minutes: 15, now: now, threads: t3Threads, entries: entries),
                       .thread(id: "1"))
    }

    func testSendArguments() {
        let project = sendArguments(.newThread(root: "/w/a"), app: .codex, defaultRoot: "/w/d")
        XCTAssertEqual(project.cwd, "/w/a")
        XCTAssertNil(project.thread)
        let toThread = sendArguments(.thread(id: "1"), app: .command, defaultRoot: "/w/d")
        XCTAssertEqual(toThread.cwd, "/w/d")
        XCTAssertEqual(toThread.thread, "1")
        let noThread = sendArguments(.thread(id: "1"), app: .claudeCode, defaultRoot: "/w/d")
        XCTAssertEqual(noThread.cwd, "/w/d")
        XCTAssertNil(noThread.thread, "only the custom command takes --thread")
    }

    func testAddFolderRow() {
        let r = rows()
        let last = r.count - 1
        XCTAssertEqual(r[last], .addFolder)
        XCTAssertEqual(popupChoice(r, at: last), .addFolder)
        XCTAssertNil(popupTarget(r, at: last), "it is not a target")
        XCTAssertEqual(popupChoice(r, at: 1), .target(.thread(id: "1")))
        XCTAssertNil(popupChoice(r, at: 0))
        XCTAssertNil(popupChoice(r, at: nil))
        XCTAssertEqual(movedSelection(r, from: last - 1, by: 1), last, "Down reaches it")
        let none: [PopupRow] = [.header("No match"), .addFolder]
        XCTAssertNil(popupSelection(none, current: nil), "never selected for you")
        XCTAssertEqual(movedSelection(none, from: nil, by: 1), 1)
        XCTAssertEqual(addFolderTitle, "Add project folder…")
        XCTAssertFalse(addFolderToolTip.isEmpty)
    }

    func testAddedFolderTarget() {
        XCTAssertEqual(addedFolderTarget(["/w/x-beta/", "/w/x-eta"], entries: entries),
                       .newThread(root: "/w/x-beta"), "the first chosen, as the list has it")
        XCTAssertNil(addedFolderTarget([], entries: entries), "cancelled: keep the target")
        XCTAssertNil(addedFolderTarget(["/w/unlisted"], entries: entries))
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
        let r = rows()  // headers at 0 and 3, items 1, 2, 4...8, the add row at 9
        XCTAssertEqual(movedSelection(r, from: 2, by: 1), 4, "skips the header")
        XCTAssertEqual(movedSelection(r, from: 4, by: -1), 2)
        XCTAssertEqual(movedSelection(r, from: 9, by: 1), 9, "stays at the end")
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

    func testLastTargetMinutes() {
        XCTAssertEqual(lastTargetMinutes(nil), 15)
        XCTAssertEqual(lastTargetMinutes(30), 30)
        XCTAssertEqual(lastTargetMinutes(NSNumber(value: 5)), 5)
        XCTAssertEqual(lastTargetMinutes("60"), 60, "a launch argument")
        XCTAssertEqual(lastTargetMinutes(0), 0)
        XCTAssertEqual(lastTargetMinutes("0"), 0)
        XCTAssertEqual(lastTargetMinutes(-3), 0)
        XCTAssertEqual(lastTargetMinutes("abc"), 15)
        XCTAssertEqual(lastTargetDefaultMinutes, 15)
        XCTAssertEqual(lastTargetMinutesKey, "lastTargetMinutes")
        XCTAssertEqual(lastTargetChoices, [0, 5, 15, 30, 60])
        XCTAssertEqual(lastTargetLabel(0), "Off")
        XCTAssertEqual(lastTargetLabel(15), "15 min")
    }

    func remembered(_ target: SendTarget?, minutesAgo: Double = 14, minutes: Int = 15) -> SendTarget? {
        rememberedTarget(target.map { LastTarget(target: $0, at: now.addingTimeInterval(-minutesAgo * 60)) },
                         minutes: minutes, now: now, threads: threads, entries: entries)
    }

    func testRememberedTarget() {
        XCTAssertNil(remembered(nil))
        XCTAssertNil(remembered(.thread(id: "1"), minutes: 0), "off")
        XCTAssertEqual(remembered(.thread(id: "1")), .thread(id: "1"))
        XCTAssertNil(remembered(.thread(id: "1"), minutesAgo: 15), "expired")
        XCTAssertNil(remembered(.thread(id: "gone")), "no longer open")
        XCTAssertEqual(remembered(.newThread(root: "/w/x-beta")), .newThread(root: "/w/x-beta"))
        XCTAssertNil(remembered(.newThread(root: "/w/removed")), "no longer a project")
    }

    func testResolveTarget() {
        func resolve(picked: SendTarget? = nil, remembered: SendTarget? = nil, detected: String? = nil,
                     entries: [PickerEntry]? = nil) -> SendTarget {
            resolveTarget(picked: picked, remembered: remembered, detectedRoot: detected,
                          entries: entries ?? self.entries, defaultRoot: "/w/default")
        }
        XCTAssertEqual(resolve(picked: .thread(id: "1"), remembered: .thread(id: "2"), detected: "/w/x-eta"),
                       .thread(id: "1"))
        XCTAssertEqual(resolve(remembered: .thread(id: "2"), detected: "/w/x-eta"), .thread(id: "2"))
        XCTAssertEqual(resolve(detected: "/w/x-eta"), .newThread(root: "/w/x-eta"))
        XCTAssertEqual(resolve(), .newThread(root: "/w/x-gamma"))
        XCTAssertEqual(resolve(entries: []), .newThread(root: "/w/default"))
    }

    func testCutTitle() {
        XCTAssertEqual(cutTitle("Short"), "Short")
        let cut = cutTitle(String(repeating: "x", count: threadTitleChars + 5))
        XCTAssertEqual(cut.count, threadTitleChars)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(cutTitle("abcdef", to: 4), "abc…")
    }

    func testTargetChip() {
        let threads = [OpenThread(id: "1", title: "Fix the picker", project: "app")]
        let entries = pickerEntries(projects: [Project(title: "A", root: "/w/a"), Project(title: "B", root: "/w/b")],
                                    defaultRoot: "/w/a")
        XCTAssertEqual(targetChip(.thread(id: "1"), threads: threads, entries: entries),
                       TargetChip(label: "→ Fix the picker", toThread: true,
                                  toolTip: "Adds to: Fix the picker · app (Tab to change)"))
        XCTAssertEqual(targetChip(.thread(id: "9"), threads: threads, entries: entries).label, "→ thread")
        XCTAssertTrue(targetChip(.thread(id: "9"), threads: threads, entries: entries).toThread)
        XCTAssertEqual(targetChip(.newThread(root: "/w/a"), threads: threads, entries: entries),
                       TargetChip(label: "+ A", toThread: false, toolTip: "New thread in /w/a (Tab to change)"))
        let other = targetChip(.newThread(root: "/w/other"), threads: threads, entries: entries)
        XCTAssertEqual(other.label, "+ other")
        XCTAssertFalse(other.toThread)
        XCTAssertEqual(other.toolTip, "New thread in /w/other (Tab to change)")
        XCTAssertEqual(targetChip(.newThread(root: "/w/a"), threads: threads, entries: entries, app: .codex).toolTip,
                       "Starts Codex in /w/a (Tab to change)")
        let long = String(repeating: "y", count: threadTitleChars + 5)
        XCTAssertEqual(targetChip(.thread(id: "2"), threads: [OpenThread(id: "2", title: long, project: "app")],
                                  entries: entries).label, "→ " + cutTitle(long))
    }

    func testTargetHint() {
        XCTAssertEqual(targetHint(hasPicker: true), "↩ send · ⇥ change")
        XCTAssertEqual(targetHint(hasPicker: false), "↩ new thread · esc dismiss")
        XCTAssertEqual(targetHint(hasPicker: true, app: .codex), "↩ send · ⇥ change")
        XCTAssertEqual(targetHint(hasPicker: false, app: .claudeApp), "↩ Claude app · esc dismiss")
        XCTAssertEqual(targetHint(hasPicker: false, app: .clipboard), "↩ Clipboard · esc dismiss")
    }

    func testSendOutcome() {
        let threads = [OpenThread(id: "1", title: "Fix the picker", project: "app")]
        XCTAssertEqual(sendOutcome(ok: false, output: "boom", target: .thread(id: "1"), threads: threads),
                       .failure("failed: boom"))
        XCTAssertEqual(sendOutcome(ok: true, output: "", target: .newThread(root: "/w/a"), threads: threads), .close)
        XCTAssertEqual(sendOutcome(ok: true, output: "", target: .thread(id: "1"), threads: threads),
                       .notice("✓ Added to Fix the picker"))
        let long = String(repeating: "z", count: threadTitleChars + 5)
        XCTAssertEqual(sendOutcome(ok: true, output: "", target: .thread(id: "2"),
                                   threads: [OpenThread(id: "2", title: long, project: "app")]),
                       .notice("✓ Added to \(cutTitle(long))"))
        XCTAssertEqual(sendOutcome(ok: true, output: "", target: .thread(id: "9"), threads: threads),
                       .notice("✓ Added to thread"))
        XCTAssertEqual(addedNoticeSeconds, 1)
    }
}
