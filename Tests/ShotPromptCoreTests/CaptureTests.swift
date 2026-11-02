import XCTest
@testable import ShotPromptCore

final class CaptureTests: XCTestCase {
    func testIsCapture() {
        XCTAssertTrue(isCapture("SCR-20261102-abc.png"))
        XCTAssertTrue(isCapture("SCR-1.jpg"))
        XCTAssertTrue(isCapture("SCR-1.jpeg"))
        XCTAssertTrue(isCapture("SCR-1.PNG"))
        XCTAssertFalse(isCapture("scr-1.png"), "prefix is case-sensitive")
        XCTAssertFalse(isCapture("Screenshot 1.png"))
        XCTAssertFalse(isCapture("SCR-1.gif"))
        XCTAssertFalse(isCapture("SCR-1.png.tmp"))
    }

    func testListCaptures() throws {
        let dir = try makeTempDir(self)
        for name in ["SCR-a.png", "SCR-b.jpeg", "notes.txt", "SCR-c.heic"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(Set(listCaptures(in: dir)), ["SCR-a.png", "SCR-b.jpeg"])
    }

    func testListCapturesMissingFolder() {
        XCTAssertEqual(listCaptures(in: URL(fileURLWithPath: "/nonexistent/\(UUID())")), [])
    }

    func testNewestCapture() {
        XCTAssertEqual(newestCapture(current: ["SCR-1.png", "SCR-3.png", "SCR-2.png"], known: ["SCR-1.png"]),
                       "SCR-3.png")
        XCTAssertNil(newestCapture(current: ["SCR-1.png"], known: ["SCR-1.png", "SCR-0.png"]))
        XCTAssertNil(newestCapture(current: [], known: []))
    }

    func testWriteCheck() {
        XCTAssertEqual(writeCheck(size: 0, lastSize: -1, tries: 0, maxTries: 20), .retry)
        XCTAssertEqual(writeCheck(size: 10, lastSize: -1, tries: 0, maxTries: 20), .retry, "first size seen")
        XCTAssertEqual(writeCheck(size: 20, lastSize: 10, tries: 1, maxTries: 20), .retry, "still growing")
        XCTAssertEqual(writeCheck(size: 20, lastSize: 20, tries: 2, maxTries: 20), .ready)
        XCTAssertEqual(writeCheck(size: 0, lastSize: 0, tries: 2, maxTries: 20), .retry, "empty is never stable")
        XCTAssertEqual(writeCheck(size: 30, lastSize: 20, tries: 21, maxTries: 20), .ready, "out of tries, take it")
        XCTAssertEqual(writeCheck(size: 0, lastSize: 0, tries: 21, maxTries: 20), .giveUp, "out of tries, still empty")
        XCTAssertEqual(writeCheck(size: 5, lastSize: 0, tries: 20, maxTries: 20), .retry, "tries equal to max still retries")
    }

    func testFileSize() throws {
        let dir = try makeTempDir(self)
        let f = dir.appendingPathComponent("x")
        FileManager.default.createFile(atPath: f.path, contents: Data(count: 7))
        XCTAssertEqual(fileSize(f), 7)
        XCTAssertEqual(fileSize(dir.appendingPathComponent("missing")), 0)
    }
}

final class CaptureWatcherTests: XCTestCase {
    func testDefaults() {
        let w = CaptureWatcher(directory: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(w.pollInterval, 0.15)
        XCTAssertEqual(w.maxTries, 20)
        w.onCapture(URL(fileURLWithPath: "/x/y")) // the default handler does nothing
    }

    func testStartFailsOnMissingFolder() {
        let path = "/nonexistent/\(UUID())"
        let w = CaptureWatcher(directory: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try w.start()) { error in
            XCTAssertEqual(error as? WatchError, .cannotOpen(path))
        }
    }

    func testNewCaptureIsReportedOnceWritten() throws {
        let dir = try makeTempDir(self)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("SCR-old.png").path, contents: Data([1]))
        let w = CaptureWatcher(directory: dir, pollInterval: 0.01)
        var seen: [URL] = []
        w.onCapture = { seen.append($0) }
        try w.start()
        defer { w.stop() }
        XCTAssertEqual(w.known, ["SCR-old.png"], "captures already there are not new")

        FileManager.default.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data([1]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("SCR-new.png").path, contents: Data([1, 2, 3]))
        spin(until: { !seen.isEmpty }, timeout: 5)
        XCTAssertEqual(seen.map(\.lastPathComponent), ["SCR-new.png"])
        XCTAssertEqual(w.known, ["SCR-old.png", "SCR-new.png"])
    }

    func testScanWithNothingNew() throws {
        let dir = try makeTempDir(self)
        let w = CaptureWatcher(directory: dir)
        var called = false
        w.onCapture = { _ in called = true }
        w.scan()
        XCTAssertFalse(called)
    }

    func testEmptyCaptureIsDroppedAfterMaxTries() throws {
        let dir = try makeTempDir(self)
        let f = dir.appendingPathComponent("SCR-empty.png")
        FileManager.default.createFile(atPath: f.path, contents: Data())
        let w = CaptureWatcher(directory: dir, maxTries: 3)
        var called = false
        w.onCapture = { _ in called = true }
        // The last try: still empty, so it is dropped without scheduling another.
        w.waitUntilWritten(f, lastSize: 0, tries: 4)
        XCTAssertFalse(called)
    }

    func testStopClosesTheFolder() throws {
        let dir = try makeTempDir(self)
        let w = CaptureWatcher(directory: dir)
        try w.start()
        w.stop()
        w.stop() // a second stop is harmless
        var called = false
        w.onCapture = { _ in called = true }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("SCR-late.png").path, contents: Data([1]))
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done = true }
        spin { done }
        XCTAssertFalse(called, "a stopped watcher reports nothing")
    }
}
