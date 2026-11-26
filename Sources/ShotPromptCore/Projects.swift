import Foundation
import SQLite3

public struct Project: Equatable {
    public let title: String
    public let root: String

    public init(title: String, root: String) {
        self.title = title
        self.root = root
    }
}

// T3's projects, pinned first, then by latest thread activity. Folders that are
// gone are left out. Any error gives an empty list, and the panel then has no picker.
public func loadProjects(databasePath: String) -> [Project] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    let uri = "file:\(databasePath)?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
    sqlite3_busy_timeout(db, 500)
    let sql = """
        SELECT p.title, p.workspace_root FROM projection_projects p
        WHERE p.deleted_at IS NULL AND p.archived_at IS NULL
        ORDER BY p.pinned_at IS NULL,
                 (SELECT max(t.updated_at) FROM orchestration_v2_projection_threads t
                  WHERE t.project_id = p.project_id) IS NULL,
                 (SELECT max(t.updated_at) FROM orchestration_v2_projection_threads t
                  WHERE t.project_id = p.project_id) DESC,
                 p.title COLLATE NOCASE
        """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    var rows: [Project] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        guard let t = sqlite3_column_text(stmt, 0), let r = sqlite3_column_text(stmt, 1) else { continue }
        let root = String(cString: r)
        if FileManager.default.fileExists(atPath: root) {
            rows.append(Project(title: String(cString: t), root: root))
        }
    }
    return rows
}

public struct PickerEntry: Equatable {
    // The menu title.
    public let name: String
    // The folder the thread opens in.
    public let root: String
    // The folder, with ~ for the home folder.
    public let toolTip: String
}

// The picker's list: the default folder first (added if T3 has no project
// there), then the rest in T3's order. Titles shown twice get their parent folder.
public func pickerEntries(projects: [Project], defaultRoot: String) -> [PickerEntry] {
    let start = (defaultRoot as NSString).standardizingPath
    var list = projects
    if let i = list.firstIndex(where: { ($0.root as NSString).standardizingPath == start }) {
        list.insert(list.remove(at: i), at: 0)
    } else {
        list.insert(Project(title: (start as NSString).lastPathComponent, root: start), at: 0)
    }
    var seen = Set<String>(), shared = Set<String>()
    for p in list where !seen.insert(p.title).inserted { shared.insert(p.title) }
    return list.map { p in
        let parent = ((p.root as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let name = shared.contains(p.title) ? "\(p.title) · \(parent)" : p.title
        return PickerEntry(name: name, root: p.root, toolTip: (p.root as NSString).abbreviatingWithTildeInPath)
    }
}

// A thread open in T3, for adding a capture to it instead of starting a new one.
public struct OpenThread: Equatable {
    public let id: String
    public let title: String
    // The title of its project.
    public let project: String

    public init(id: String, title: String, project: String) {
        self.id = id
        self.title = title
        self.project = project
    }
}

// How many threads the picker lists.
public let maxThreads = 10

// T3's open threads, most recently active first: not archived, deleted or
// settled, and not a subagent's thread or a side chat. These are the threads
// T3's sidebar shows as open. Any error gives an empty list.
public func loadThreads(databasePath: String, limit: Int = maxThreads) -> [OpenThread] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    let uri = "file:\(databasePath)?mode=ro"
    guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
    sqlite3_busy_timeout(db, 500)
    let sql = """
        SELECT t.thread_id, t.title, p.title FROM orchestration_v2_projection_threads t
        JOIN projection_projects p ON p.project_id = t.project_id
        WHERE t.thread_id IS NOT NULL AND t.title IS NOT NULL AND p.title IS NOT NULL
          AND t.deleted_at IS NULL AND t.archived_at IS NULL
          AND p.deleted_at IS NULL AND p.archived_at IS NULL
          AND json_valid(t.payload_json)
          AND json_extract(t.payload_json, '$.settledAt') IS NULL
          AND json_extract(t.payload_json, '$.lineage.relationshipToParent') IS NOT 'subagent'
          AND coalesce(json_extract(t.payload_json, '$.lineage.sideChat'), 0) = 0
        ORDER BY t.updated_at DESC
        LIMIT ?
        """
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    sqlite3_bind_int(stmt, 1, Int32(limit))
    var rows: [OpenThread] = []
    // The query leaves out NULLs, so every column has text.
    func text(_ column: Int32) -> String { String(cString: sqlite3_column_text(stmt, column)) }
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append(OpenThread(id: text(0), title: text(1), project: text(2)))
    }
    return rows
}

// Where Enter sends the prompt.
public enum SendTarget: Equatable {
    // A new thread in this project folder.
    case newThread(root: String)
    // An existing thread.
    case thread(id: String)
}

// Longest thread title the picker shows; the selected one sets the picker's width.
public let threadTitleChars = 36

public struct ThreadEntry: Equatable {
    // The menu title: the thread's title, cut to threadTitleChars.
    public let name: String
    public let id: String
    // The full title and its project.
    public let toolTip: String
}

public func threadEntries(_ threads: [OpenThread]) -> [ThreadEntry] {
    threads.map { t in
        let name = t.title.count > threadTitleChars ? String(t.title.prefix(threadTitleChars - 1)) + "…" : t.title
        return ThreadEntry(name: name, id: t.id, toolTip: "\(t.title) · \(t.project)")
    }
}

// The hint next to the picker; shorter when the picker takes room.
public func statusHint(hasProjects: Bool, toThread: Bool = false) -> String {
    if toThread { return "↩ add to thread · ⇥ change · esc" }
    return hasProjects ? "↩ new thread · ⇥ project · esc" : "↩ new T3 thread · esc dismiss"
}
