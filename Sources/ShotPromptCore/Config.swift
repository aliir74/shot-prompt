import Foundation

// Settings read from the environment, with their defaults.
public struct Config {
    public let environment: [String: String]
    public let home: URL
    // Where Shottr saves captures.
    public let captureDir: URL
    // Every folder watched for screenshots: Shottr's, then macOS's own.
    public let captureDirs: [URL]
    // The command that opens the T3 thread.
    public let dispatchBin: String
    // The project folder the new thread opens in, unless you pick another.
    public let threadCwd: String
    // T3 Code's database, read only for its list of projects.
    public let t3Database: String

    // `screenshotLocation` is macOS's screencapture "location" setting, if set.
    public init(environment: [String: String], home: URL, screenshotLocation: String? = nil) {
        self.environment = environment
        self.home = home
        captureDir = URL(fileURLWithPath: environment["SHOT_PROMPT_CAPTURE_DIR"]
            ?? home.appendingPathComponent("Pictures").path)
        captureDirs = uniqueFolders([captureDir, screenshotFolder(location: screenshotLocation, home: home)])
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
// The walk through a window's accessibility tree for its web page's address
// stops after this many nodes or this long. An Electron app's page is near
// the top; the caps bound a window that has none.
public let webAreaSearchLimit = 1500
public let webAreaSearchSeconds: TimeInterval = 0.5
// Hide the menu bar icon (and with it the settings menu) with
// `defaults write io.github.aliir74.shot-prompt showMenuBarIcon -bool false`.
public let showMenuBarIconKey = "showMenuBarIcon"
