import XCTest
@testable import ShotPromptCore

final class ConfigTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone")

    func testDefaults() {
        let c = Config(environment: [:], home: home)
        XCTAssertEqual(c.captureDir.path, "/Users/someone/Pictures")
        XCTAssertEqual(c.dispatchBin, "/Users/someone/.local/bin/t3-dispatch")
        XCTAssertEqual(c.threadCwd, "/Users/someone")
        XCTAssertEqual(c.t3Database, "/Users/someone/.t3/userdata/statev2.sqlite")
        XCTAssertEqual(c.home, home)
        XCTAssertEqual(c.environment, [:])
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
    }
}
