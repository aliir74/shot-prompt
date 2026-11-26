import Foundation

// T3 stores times as ISO 8601 in UTC, usually with milliseconds. Anything
// else (a bare date, an empty string) gives nil.
public func parseT3Date(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: text)
}

// How long ago, in the largest whole unit: now, 5m, 3h, 2d. A time in the
// future counts as now.
public func relativeTime(from date: Date, now: Date) -> String {
    let seconds = max(Int(now.timeIntervalSince(date)), 0)
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

// The grey text on a thread's row: its project and how long ago it was active.
public func threadDetail(_ thread: OpenThread, now: Date) -> String {
    guard let d = thread.updatedAt else { return thread.project }
    return "\(thread.project) · \(relativeTime(from: d, now: now))"
}

// Every typed word must appear somewhere in the fields, in any order and in
// any field, ignoring case. An empty query matches everything.
public func matchesQuery(_ query: String, fields: [String]) -> Bool {
    let text = fields.joined(separator: "\n").lowercased()
    return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
}

// A row you can pick in the target popup.
public struct PopupItem: Equatable {
    public let target: SendTarget
    // The full thread title or the project's name.
    public let title: String
    // Grey text on the right: a thread's project and time ago; empty for a project.
    public let detail: String
    public let toolTip: String
}

public enum PopupRow: Equatable {
    // A section title; it cannot be picked.
    case header(String)
    case item(PopupItem)
}

// How many projects the popup lists before you type.
public let maxPopupProjects = 5

// The popup: open threads first, then projects for a new thread. Before you
// type, the projects are the detected one, the default, the current target's
// and then the rest, cut to maxPopupProjects; typing searches all projects in
// that same order. A section with no rows has no header.
public func popupRows(threads: [OpenThread], entries: [PickerEntry], detectedRoot: String?,
                      current: SendTarget, query: String, now: Date) -> [PopupRow] {
    let threadRows = threads.filter { matchesQuery(query, fields: [$0.title, $0.project]) }.map {
        PopupRow.item(PopupItem(target: .thread(id: $0.id), title: $0.title, detail: threadDetail($0, now: now),
                                toolTip: "\($0.title) · \($0.project)"))
    }
    var currentRoot: String?
    if case .newThread(let root) = current { currentRoot = root }
    let first = [detectedRoot, entries.first?.root, currentRoot].compactMap { root in
        entries.first { $0.root == root }
    }
    var seen = Set<String>()
    var ordered = (first + entries).filter { seen.insert($0.root).inserted }
    if query.allSatisfy(\.isWhitespace) {
        ordered = Array(ordered.prefix(maxPopupProjects))
    } else {
        ordered = ordered.filter {
            matchesQuery(query, fields: [$0.name, ($0.root as NSString).lastPathComponent])
        }
    }
    let projectRows = ordered.map {
        PopupRow.item(PopupItem(target: .newThread(root: $0.root), title: $0.name, detail: "", toolTip: $0.toolTip))
    }
    var rows: [PopupRow] = []
    if !threadRows.isEmpty { rows += [.header("Add to an open thread")] + threadRows }
    if !projectRows.isEmpty { rows += [.header("New thread in")] + projectRows }
    return rows.isEmpty ? [.header("No match")] : rows
}

// The indexes of the rows that can be picked.
func itemIndexes(_ rows: [PopupRow]) -> [Int] {
    rows.indices.filter {
        if case .item = rows[$0] { return true }
        return false
    }
}

// The row to select: the current target's, else the first item.
public func popupSelection(_ rows: [PopupRow], current: SendTarget?) -> Int? {
    let items = itemIndexes(rows)
    return items.first { popupTarget(rows, at: $0) == current } ?? items.first
}

// Up and Down move between items, skipping headers, and stop at either end.
public func movedSelection(_ rows: [PopupRow], from index: Int?, by delta: Int) -> Int? {
    let items = itemIndexes(rows)
    guard let first = items.first else { return nil }
    guard let i = index, let pos = items.firstIndex(of: i) else { return first }
    return items[min(max(pos + delta, 0), items.count - 1)]
}

public func popupTarget(_ rows: [PopupRow], at index: Int?) -> SendTarget? {
    guard let i = index, rows.indices.contains(i), case .item(let item) = rows[i] else { return nil }
    return item.target
}

public enum PopupCommand: Equatable {
    case up, down, pick, close, none
}

// Keys in the popup's search field. Tab and Shift+Tab close it, like Esc.
public func popupCommand(_ selector: String) -> PopupCommand {
    switch selector {
    case "moveUp:": return .up
    case "moveDown:": return .down
    case "insertNewline:": return .pick
    case "cancelOperation:", "insertTab:", "insertBacktab:": return .close
    default: return .none
    }
}

// A click on the chip first takes the keys from the popup, which closes it;
// the same click must not open it again.
public let popupReopenGuardSeconds: TimeInterval = 0.3

public func chipClickToggles(closedAt: Date?, now: Date) -> Bool {
    guard let c = closedAt else { return true }
    return now.timeIntervalSince(c) >= popupReopenGuardSeconds
}

// How long the panel starts on the last thread or project you sent to.
public let lastTargetMinutesKey = "lastTargetMinutes"
public let lastTargetDefaultMinutes = 15
// The gear menu's choices; 0 is off.
public let lastTargetChoices = [0, 5, 15, 30, 60]

// The setting as stored: a number from the gear menu, or a string from a
// launch argument. Negative is off; missing or unreadable is the default.
public func lastTargetMinutes(_ stored: Any?) -> Int {
    var value: Int?
    if let n = stored as? Int { value = n } else if let s = stored as? String { value = Int(s) }
    guard let v = value else { return lastTargetDefaultMinutes }
    return max(v, 0)
}

public func lastTargetLabel(_ minutes: Int) -> String {
    minutes == 0 ? "Off" : "\(minutes) min"
}

// Where the last send went, and when.
public struct LastTarget: Equatable {
    public let target: SendTarget
    public let at: Date

    public init(target: SendTarget, at: Date) {
        self.target = target
        self.at = at
    }
}

// The last target, while it is younger than `minutes` and its thread is still
// open or its project still listed.
public func rememberedTarget(_ last: LastTarget?, minutes: Int, now: Date, threads: [OpenThread],
                             entries: [PickerEntry]) -> SendTarget? {
    guard let last, now.timeIntervalSince(last.at) < Double(minutes * 60) else { return nil }
    switch last.target {
    case .thread(let id): return threads.contains { $0.id == id } ? last.target : nil
    case .newThread(let root): return entries.contains { $0.root == root } ? last.target : nil
    }
}

// The target the panel starts on: what you picked, else the remembered
// target, else the detected project, else the default folder.
public func resolveTarget(picked: SendTarget?, remembered: SendTarget?, detectedRoot: String?,
                          entries: [PickerEntry], defaultRoot: String) -> SendTarget {
    picked ?? remembered ?? .newThread(root: detectedRoot ?? entries.first?.root ?? defaultRoot)
}
