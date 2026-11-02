import XCTest
@testable import ShotPromptCore

final class DispatchTests: XCTestCase {
    func script(_ body: String) throws -> String {
        let path = try makeTempDir(self).appendingPathComponent("t3-dispatch").path
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    let home = URL(fileURLWithPath: "/Users/someone")

    func testArgumentsEnvironmentAndSuccess() throws {
        let bin = try script("""
            for a in "$@"; do echo "arg:$a"; done
            echo "path:$PATH"
            echo "keep:$KEEP"
            """)
        let r = dispatch(executable: bin, prompt: "what is this?", image: URL(fileURLWithPath: "/tmp/SCR-1.png"),
                         cwd: "/work/proj", environment: ["KEEP": "yes", "PATH": "/nope"], home: home)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.output, """
            arg:--cwd
            arg:/work/proj
            arg:--image
            arg:/tmp/SCR-1.png
            arg:what is this?
            path:/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
            keep:yes
            """)
    }

    func testFailureMergesStderr() throws {
        let bin = try script("echo out; echo 'boom' >&2; exit 2\n")
        let r = dispatch(executable: bin, prompt: "p", image: URL(fileURLWithPath: "/i.png"),
                         cwd: "/", environment: [:], home: home)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.output, "out\nboom")
    }

    func testLargeOutputDoesNotHang() throws {
        // More than a pipe buffer (64 KB): reading must not wait for exit.
        let bin = try script("head -c 200000 /dev/zero | tr '\\\\0' x\n")
        let r = dispatch(executable: bin, prompt: "p", image: URL(fileURLWithPath: "/i.png"),
                         cwd: "/", environment: [:], home: home)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.output.count, 200000)
    }

    func testMissingExecutable() {
        let r = dispatch(executable: "/nonexistent/\(UUID())", prompt: "p", image: URL(fileURLWithPath: "/i.png"),
                         cwd: "/", environment: [:], home: home)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(r.output.isEmpty)
    }

    func testSendablePrompt() {
        XCTAssertEqual(sendablePrompt("  fix this\n"), "fix this")
        XCTAssertNil(sendablePrompt(" \n\t "))
        XCTAssertNil(sendablePrompt(""))
    }
}
