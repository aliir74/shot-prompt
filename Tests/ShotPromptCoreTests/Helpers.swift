import Foundation
import XCTest

// A fresh folder under the system temp dir, removed when the test ends.
func makeTempDir(_ test: XCTestCase) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShotPromptTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    // Resolve /var -> /private/var so paths compare equal to what the code sees.
    return dir.resolvingSymlinksInPath()
}

// Runs the main run loop until the condition holds or the timeout passes.
func spin(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
