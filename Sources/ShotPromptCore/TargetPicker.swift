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
    // The last row: choose folders to add to the projects.
    case addFolder
}

public let addFolderTitle = "Add project folder…"
public let addFolderToolTip = "Choose folders to list here; the ones you send to are added on their own."

// What picking a row does: send there, or add a folder.
public enum PopupChoice: Equatable {
    case target(SendTarget)
    case addFolder
}

// The threads the picker offers: T3's open threads when the target can add
// to one, else none, so a remembered thread falls back to a project. `load`
// runs only when they are wanted.
public func pickerThreads(app: Target, load: () -> [OpenThread]) -> [OpenThread] {
    app.addsToThreads ? load() : []
}

// The title over the projects: T3 opens a new thread, the others start in the folder.
public func projectsHeader(app: Target) -> String {
    app == .command ? "New thread in" : "Start \(app.title) in"
}

public func popupPlaceholder(app: Target) -> String {
    app.addsToThreads ? "Search threads and projects" : "Search projects"
}

// How many projects the popup lists before you type.
public let maxPopupProjects = 5

// The popup: open threads first, then projects for a new thread, then the
// row that adds a folder. Before you type, the projects are the detected one,
// the default, the current target's and then the rest, cut to
// maxPopupProjects; typing searches all projects in that same order. A
// section with no rows has no header.
public func popupRows(threads: [OpenThread], entries: [PickerEntry], detectedRoot: String?,
                      current: SendTarget, query: String, now: Date, app: Target = .command) -> [PopupRow] {
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
    if !projectRows.isEmpty { rows += [.header(projectsHeader(app: app))] + projectRows }
    return (rows.isEmpty ? [.header("No match")] : rows) + [.addFolder]
}

// The indexes of the rows that can be picked.
func itemIndexes(_ rows: [PopupRow]) -> [Int] {
    rows.indices.filter {
        if case .header = rows[$0] { return false }
        return true
    }
}

// The row to select: the current target's, else the first target. The add
// row is never selected for you, so Enter on "No match" adds nothing.
public func popupSelection(_ rows: [PopupRow], current: SendTarget?) -> Int? {
    let targets = itemIndexes(rows).filter { popupTarget(rows, at: $0) != nil }
    return targets.first { current != nil && popupTarget(rows, at: $0) == current } ?? targets.first
}

// Up and Down move between items, skipping headers, and stop at either end.
public func movedSelection(_ rows: [PopupRow], from index: Int?, by delta: Int) -> Int? {
    let items = itemIndexes(rows)
    guard let first = items.first else { return nil }
    guard let i = index, let pos = items.firstIndex(of: i) else { return first }
    return items[min(max(pos + delta, 0), items.count - 1)]
}

public func popupTarget(_ rows: [PopupRow], at index: Int?) -> SendTarget? {
    guard case .target(let t) = popupChoice(rows, at: index) else { return nil }
    return t
}

public func popupChoice(_ rows: [PopupRow], at index: Int?) -> PopupChoice? {
    guard let i = index, rows.indices.contains(i) else { return nil }
    switch rows[i] {
    case .header: return nil
    case .item(let item): return .target(item.target)
    case .addFolder: return .addFolder
    }
}

// After "Add project folder…": the first folder you chose, as the projects
// list it, or nil when you chose none (the target stays as it was).
public func addedFolderTarget(_ added: [String], entries: [PickerEntry]) -> SendTarget? {
    guard let first = added.first.map({ ($0 as NSString).standardizingPath }),
          let entry = entries.first(where: { ($0.root as NSString).standardizingPath == first }) else { return nil }
    return .newThread(root: entry.root)
}

// The folder and thread a send goes to. A thread only reaches the custom
// command; any other target starts in the default folder.
public func sendArguments(_ target: SendTarget, app: Target, defaultRoot: String) -> (cwd: String, thread: String?) {
    switch target {
    case .newThread(let root): return (root, nil)
    case .thread(let id): return (defaultRoot, app.addsToThreads ? id : nil)
    }
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

// A long thread title, cut with an ellipsis to `chars` characters.
public func cutTitle(_ title: String, to chars: Int = threadTitleChars) -> String {
    title.count > chars ? String(title.prefix(chars - 1)) + "…" : title
}

// The chip at the bottom right of the panel that names where Enter sends.
public struct TargetChip: Equatable {
    public let label: String
    // Blue for an existing thread, grey for a new thread in a project.
    public let toThread: Bool
    public let toolTip: String
}

public func targetChip(_ target: SendTarget, threads: [OpenThread], entries: [PickerEntry],
                       app: Target = .command) -> TargetChip {
    switch target {
    case .thread(let id):
        guard let t = threads.first(where: { $0.id == id }) else {
            return TargetChip(label: "→ thread", toThread: true, toolTip: "Adds to an open thread (Tab to change)")
        }
        return TargetChip(label: "→ \(cutTitle(t.title))", toThread: true,
                          toolTip: "Adds to: \(t.title) · \(t.project) (Tab to change)")
    case .newThread(let root):
        let entry = entries.first { $0.root == root }
        let name = entry?.name ?? (root as NSString).lastPathComponent
        let folder = entry?.toolTip ?? (root as NSString).abbreviatingWithTildeInPath
        let action = app == .command ? "New thread in" : "Starts \(app.title) in"
        return TargetChip(label: "+ \(name)", toThread: false, toolTip: "\(action) \(folder) (Tab to change)")
    }
}

// The hint next to the gear; the chip says where Enter sends. A target with
// no project (a chat app, the clipboard) has no chip, so the hint names it.
public func targetHint(hasPicker: Bool, app: Target = .command) -> String {
    let name = app == .command ? "new thread" : app.title
    return hasPicker ? "↩ send · ⇥ change" : "↩ \(name) · esc dismiss"
}

// How long "✓ Added to" shows before the panel closes.
public let addedNoticeSeconds: TimeInterval = 1

public enum SendOutcome: Equatable {
    // A new thread opens in T3, which is confirmation enough.
    case close
    // Added to an existing thread: show this, then close.
    case notice(String)
    // Show this in red and keep the panel.
    case failure(String)
}

public func sendOutcome(ok: Bool, output: String, target: SendTarget, threads: [OpenThread]) -> SendOutcome {
    guard ok else { return .failure("failed: \(output)") }
    guard case .thread(let id) = target else { return .close }
    let title = threads.first { $0.id == id }.map { cutTitle($0.title) } ?? "thread"
    return .notice("✓ Added to \(title)")
}
