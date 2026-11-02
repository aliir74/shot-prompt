import SQLite3
import XCTest
@testable import ShotPromptCore

final class ProjectTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDir(self)
    }

    // A folder that exists, for a project root.
    func folder(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func makeDB(_ statements: [String]) throws -> String {
        let path = dir.appendingPathComponent("state.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                XCTFail("\(sql): \(String(cString: err!))")
            }
        }
        return path
    }

    let schema = [
        """
        CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT, workspace_root TEXT,
            pinned_at TEXT, archived_at TEXT, deleted_at TEXT)
        """,
        "CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, project_id TEXT, updated_at TEXT)",
    ]

    func project(_ id: String, _ title: String?, _ root: String?, pinned: String? = nil,
                 archived: String? = nil, deleted: String? = nil) -> String {
        func q(_ s: String?) -> String { s.map { "'\($0)'" } ?? "NULL" }
        return "INSERT INTO projection_projects VALUES ('\(id)', \(q(title)), \(q(root)), "
            + "\(q(pinned)), \(q(archived)), \(q(deleted)))"
    }

    func thread(_ project: String, _ updated: String) -> String {
        "INSERT INTO orchestration_v2_projection_threads VALUES ('\(UUID())', '\(project)', '\(updated)')"
    }

    func testOrderingAndFiltering() throws {
        let path = try makeDB(schema + [
            // No threads: after everything with activity, then by title ignoring case.
            project("quiet-b", "beta", try folder("beta")),
            project("quiet-a", "Alpha", try folder("alpha")),
            // Activity: latest first.
            project("old", "Old", try folder("old")),
            thread("old", "2026-01-01"),
            project("recent", "Recent", try folder("recent")),
            thread("recent", "2026-03-01"),
            thread("recent", "2025-01-01"),
            // Pinned beats any activity.
            project("pinned", "Pinned", try folder("pinned"), pinned: "2026-01-01"),
            // Left out.
            project("archived", "Archived", try folder("archived"), archived: "2026-01-01"),
            thread("archived", "2027-01-01"),
            project("deleted", "Deleted", try folder("deleted"), deleted: "2026-01-01"),
            project("gone", "Gone", dir.appendingPathComponent("gone").path),
            thread("gone", "2027-01-01"),
            project("no-title", nil, try folder("nt")),
            project("no-root", "No root", nil),
        ])
        XCTAssertEqual(loadProjects(databasePath: path).map(\.title),
                       ["Pinned", "Recent", "Old", "Alpha", "beta"])
        XCTAssertEqual(loadProjects(databasePath: path).first?.root, dir.appendingPathComponent("pinned").path)
    }

    func testMissingDatabase() {
        XCTAssertEqual(loadProjects(databasePath: dir.appendingPathComponent("none.sqlite").path), [])
    }

    func testDatabaseWithoutTables() throws {
        XCTAssertEqual(loadProjects(databasePath: try makeDB(["CREATE TABLE other (x)"])), [])
    }

    func testOpensReadOnly() throws {
        let path = try makeDB(schema + [project("a", "A", try folder("a"))])
        _ = loadProjects(databasePath: path)
        // The file is untouched: no journal or WAL left behind by a writer.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-journal"))
    }
}

final class PickerTests: XCTestCase {
    func titles(_ e: [PickerEntry]) -> [String] { e.map(\.name) }

    func testDefaultProjectMovesFirst() {
        let projects = [Project(title: "A", root: "/w/a"), Project(title: "B", root: "/w/b")]
        let e = pickerEntries(projects: projects, defaultRoot: "/w/b/")
        XCTAssertEqual(titles(e), ["B", "A"])
        XCTAssertEqual(e.map(\.root), ["/w/b", "/w/a"])
    }

    func testDefaultFolderAddedWhenNotAProject() {
        let e = pickerEntries(projects: [Project(title: "A", root: "/w/a")], defaultRoot: "/w/x/../vault")
        XCTAssertEqual(e.first, PickerEntry(name: "vault", root: "/w/vault", toolTip: "/w/vault"))
        XCTAssertEqual(titles(e), ["vault", "A"])
    }

    func testDuplicateTitlesGetParentFolder() {
        let projects = [
            Project(title: "app", root: "/work/ovou/app"),
            Project(title: "app", root: "/work/personal/app"),
            Project(title: "solo", root: "/work/solo"),
        ]
        let e = pickerEntries(projects: projects, defaultRoot: "/work/solo")
        XCTAssertEqual(titles(e), ["solo", "app · ovou", "app · personal"])
    }

    func testDefaultFolderNameCanCollide() {
        let e = pickerEntries(projects: [Project(title: "notes", root: "/a/notes")], defaultRoot: "/b/notes")
        XCTAssertEqual(titles(e), ["notes · b", "notes · a"])
    }

    func testToolTipAbbreviatesHome() {
        let root = NSHomeDirectory() + "/code/x"
        let e = pickerEntries(projects: [Project(title: "x", root: root)], defaultRoot: root)
        XCTAssertEqual(e.first?.toolTip, "~/code/x")
    }

    func testStatusHint() {
        XCTAssertEqual(statusHint(hasProjects: true), "↩ new thread · ⇥ project · esc")
        XCTAssertEqual(statusHint(hasProjects: false), "↩ new T3 thread · esc dismiss")
    }
}
