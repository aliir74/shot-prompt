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

// The hint next to the picker; shorter when the picker takes room.
public func statusHint(hasProjects: Bool) -> String {
    hasProjects ? "↩ new thread · ⇥ project · esc" : "↩ new T3 thread · esc dismiss"
}
