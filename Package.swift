// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShotPrompt",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShotPrompt", targets: ["ShotPrompt"]),
    ],
    targets: [
        // Everything that decides something: tested, and held to 100% line coverage.
        .target(name: "ShotPromptCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The AppKit shell: windows, views, event monitors, timers, observers.
        .executableTarget(name: "ShotPrompt", dependencies: ["ShotPromptCore"]),
        .testTarget(name: "ShotPromptCoreTests", dependencies: ["ShotPromptCore"]),
    ]
)
