import XCTest
@testable import ShotPromptCore

final class ConfigTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testDefaults() {
        let c = Config(environment: [:], home: home)
        XCTAssertEqual(c.captureDir.path, "/Users/someone/Pictures")
        XCTAssertEqual(c.captureDirs.map(\.path), ["/Users/someone/Pictures", "/Users/someone/Desktop"])
        XCTAssertEqual(c.dispatchBin, "/Users/someone/.local/bin/t3-dispatch")
        XCTAssertEqual(c.threadCwd, "/Users/someone")
        XCTAssertEqual(c.t3Database, "/Users/someone/.t3/userdata/statev2.sqlite")
        XCTAssertEqual(c.home, home)
        XCTAssertEqual(c.environment, [:])
        XCTAssertNil(c.cwdFromEnvironment)
        XCTAssertFalse(c.dispatchFromEnvironment)
    }

    func testEnvironmentOverrides() {
        let env = [
            "SHOT_PROMPT_CAPTURE_DIR": "/tmp/caps",
            "SHOT_PROMPT_DISPATCH": "/bin/d",
            "SHOT_PROMPT_CWD": "/work/proj",
            "SHOT_PROMPT_T3_DB": "/db.sqlite",
        ]
        let c = Config(environment: env, home: home)
        XCTAssertEqual(c.captureDir.path, "/tmp/caps")
        XCTAssertEqual(c.dispatchBin, "/bin/d")
        XCTAssertEqual(c.threadCwd, "/work/proj")
        XCTAssertEqual(c.t3Database, "/db.sqlite")
        XCTAssertEqual(c.environment, env)
        XCTAssertEqual(c.cwdFromEnvironment, "/work/proj")
        XCTAssertTrue(c.dispatchFromEnvironment)
    }

    func testScreenshotLocation() {
        let c = Config(environment: [:], home: home, screenshotLocation: "~/Pictures")
        XCTAssertEqual(c.captureDirs.map(\.path), ["/Users/someone/Pictures"], "one folder for both tools")
        let d = Config(environment: [:], home: home, screenshotLocation: "/shots")
        XCTAssertEqual(d.captureDirs.map(\.path), ["/Users/someone/Pictures", "/shots"])
    }
}
