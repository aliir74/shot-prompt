import Foundation

// Settings read from the environment, with their defaults.
public struct Config {
    public let environment: [String: String]
    public let home: URL
    // Where Shottr saves captures.
    public let captureDir: URL
    // The command that opens the T3 thread.
    public let dispatchBin: String
    // The project folder the new thread opens in, unless you pick another.
    public let threadCwd: String
    // T3 Code's database, read only for its list of projects.
    public let t3Database: String

    public init(environment: [String: String], home: URL) {
        self.environment = environment
        self.home = home
        captureDir = URL(fileURLWithPath: environment["SHOT_PROMPT_CAPTURE_DIR"]
            ?? home.appendingPathComponent("Pictures").path)
        dispatchBin = environment["SHOT_PROMPT_DISPATCH"]
            ?? home.appendingPathComponent(".local/bin/t3-dispatch").path
        threadCwd = environment["SHOT_PROMPT_CWD"] ?? home.path
        t3Database = environment["SHOT_PROMPT_T3_DB"]
            ?? home.appendingPathComponent(".t3/userdata/statev2.sqlite").path
    }
}

// Before you type in the panel, it closes after this long idle.
public let idleSeconds: TimeInterval = 5
// The icon waits longer: it is small and keeps out of the way.
public let iconSeconds: TimeInterval = 20
// After you switch to another app, the icon leaves this soon.
public let iconAwaySeconds: TimeInterval = 3
// After Fn comes up, dictation has this long to type into the empty prompt.
public let dictationGraceSeconds: TimeInterval = 10
// The prompt grows up to this many lines, then scrolls.
public let maxPromptLines: Double = 6
