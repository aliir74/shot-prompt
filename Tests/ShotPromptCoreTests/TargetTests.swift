import ImageIO
import XCTest
@testable import ShotPromptCore

final class TargetTests: XCTestCase {
    func testTargetProperties() {
        XCTAssertEqual(Target.allCases.map(\.title), ["Claude Code", "Codex", "Cursor Agent", "Claude app",
                                                      "ChatGPT app", "Custom command (T3 Code)", "Clipboard"])
        XCTAssertEqual(Target.allCases.map(\.executable), ["claude", "codex", "cursor-agent", nil, nil, nil, nil])
        XCTAssertEqual(Target.allCases.map(\.bundleIDs),
                       [[], [], [], ["com.anthropic.claudefordesktop"], ["com.openai.codex", "com.openai.chat"], [], []])
        XCTAssertEqual(Target.allCases.filter(\.isChatApp), [.claudeApp, .chatGPT])
        XCTAssertEqual(Target.allCases.filter(\.usesProject), [.claudeCode, .codex, .cursorAgent, .command], "not chat apps or the clipboard")
    }

    func testCurrentTarget() {
        let none: (Target) -> Bool = { _ in false }
        XCTAssertEqual(currentTarget(stored: "codex", dispatchFromEnvironment: true, isInstalled: none), .codex,
                       "your pick wins")
        XCTAssertEqual(currentTarget(stored: "gone", dispatchFromEnvironment: true, isInstalled: none), .command,
                       "an old install keeps its command")
        XCTAssertEqual(currentTarget(stored: nil, dispatchFromEnvironment: false, isInstalled: { $0 == .chatGPT }),
                       .chatGPT)
        XCTAssertEqual(currentTarget(stored: nil, dispatchFromEnvironment: false,
                                     isInstalled: { $0 == .codex || $0 == .claudeApp }), .codex, "CLIs first")
        XCTAssertEqual(currentTarget(stored: nil, dispatchFromEnvironment: false, isInstalled: none), .clipboard,
                       "nothing installed: the clipboard works anywhere")
    }

    func testFindExecutable() throws {
        let dir = try makeTempDir(self)
        let bin = dir.appendingPathComponent("tool")
        FileManager.default.createFile(atPath: bin.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: dir.appendingPathComponent("plain").path, contents: Data())
        XCTAssertEqual(findExecutable("tool", in: ["/nonexistent", dir.path]), bin.path)
        XCTAssertNil(findExecutable("plain", in: [dir.path]), "not executable")
        XCTAssertNil(findExecutable("missing", in: [dir.path]))
        let path = cliSearchPath(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(path.first, "/Users/x/.local/bin")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("a b"), "'a b'")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote("$(rm -rf ~) `x`"), "'$(rm -rf ~) `x`'")
    }

    func testPromptWithImagePaths() {
        let a = URL(fileURLWithPath: "/s/a.png"), b = URL(fileURLWithPath: "/s/b.png")
        XCTAssertEqual(promptWithImagePaths("hi", images: []), "hi")
        XCTAssertEqual(promptWithImagePaths("hi", images: [a]), "hi\n\nScreenshot (read the image file):\n- /s/a.png")
        XCTAssertEqual(promptWithImagePaths("hi", images: [a, b]),
                       "hi\n\nScreenshots (read the image files):\n- /s/a.png\n- /s/b.png")
    }

    func testTerminalArguments() {
        let a = URL(fileURLWithPath: "/s/a.png"), b = URL(fileURLWithPath: "/s/b.png")
        XCTAssertEqual(terminalArguments(.codex, prompt: "why?", images: [a, b]),
                       ["--image=/s/a.png", "--image=/s/b.png", "--", "why?"])
        XCTAssertEqual(terminalArguments(.claudeCode, prompt: "why?", images: [a]),
                       ["why?\n\nScreenshot (read the image file):\n- /s/a.png"])
        XCTAssertEqual(terminalArguments(.cursorAgent, prompt: "why?", images: [a]),
                       ["why?\n\nScreenshot (read the image file):\n- /s/a.png"])
    }

    func testTerminalScript() {
        let a = URL(fileURLWithPath: "/s/a.png")
        XCTAssertEqual(terminalScript(.codex, executable: "/opt/homebrew/bin/codex", prompt: "it's broken",
                                      images: [a], cwd: "/work/my app"), """
            #!/bin/zsh -il
            rm -f -- "$0"
            cd '/work/my app' || exit 1
            clear
            exec '/opt/homebrew/bin/codex' '--image=/s/a.png' '--' 'it'\\''s broken'

            """)
        XCTAssertTrue(terminalScript(.cursorAgent, executable: nil, prompt: "x", images: [], cwd: "/w")
            .contains("exec 'cursor-agent' 'x'"), "unfound CLI: the shell's PATH finds it")
        XCTAssertTrue(terminalScript(.claudeApp, executable: nil, prompt: "x", images: [], cwd: "/w")
            .contains("exec 'false'"), "a non-CLI target runs nothing")
    }

    func testStageAndPrune() throws {
        let dir = try makeTempDir(self)
        let src = dir.appendingPathComponent("Screenshot 1.02\u{202F}PM.PNG")
        FileManager.default.createFile(atPath: src.path, contents: Data([1, 2]))

        let root = dir.appendingPathComponent("sent")
        let copies = try stageImages([src, src], in: root.appendingPathComponent("one"))
        XCTAssertEqual(copies.map(\.lastPathComponent), ["shot-1.png", "shot-2.png"])
        XCTAssertEqual(FileManager.default.contents(atPath: copies[0].path), Data([1, 2]))
        XCTAssertThrowsError(try stageImages([dir.appendingPathComponent("missing.png")],
                                             in: root.appendingPathComponent("two")))
        XCTAssertThrowsError(try stageImages([src], in: src.appendingPathComponent("under-a-file")))

        let heic = dir.appendingPathComponent("Screenshot.heic")
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(count: 16) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let converted = try stageImages([heic], in: root.appendingPathComponent("four"))
        XCTAssertEqual(converted.map(\.lastPathComponent), ["shot-1.png"], "HEIC becomes PNG")
        XCTAssertNotNil(pngData(of: converted[0]))
        XCTAssertThrowsError(try stageImages([dir.appendingPathComponent("missing.heic")],
                                             in: root.appendingPathComponent("five")), "unreadable HEIC")

        pruneStaged(in: root, now: Date(), maxAge: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one").path), "new: kept")
        pruneStaged(in: root, now: Date().addingTimeInterval(7200), maxAge: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("one").path), "old: gone")
        pruneStaged(in: dir.appendingPathComponent("missing"), now: Date(), maxAge: 0)
    }

    func testRememberFolder() {
        XCTAssertEqual(rememberFolder("/b", in: ["/a", "/b", "/c"]), ["/b", "/a", "/c"])
        XCTAssertEqual(rememberFolder("/a/../d/", in: ["/a"]), ["/d", "/a"])
        XCTAssertEqual(rememberFolder("/z", in: ["/a", "/b"], limit: 2), ["/z", "/a"])
    }

    func testMergeProjects() {
        let t3 = [Project(title: "app", root: "/w/app")]
        let merged = mergeProjects(t3: t3, recent: ["/w/app/", "/w/site", "/gone"], exists: { $0 != "/gone" })
        XCTAssertEqual(merged, [Project(title: "app", root: "/w/app"), Project(title: "site", root: "/w/site")])
        XCTAssertEqual(mergeProjects(t3: [], recent: [NSTemporaryDirectory()]).count, 1, "checks the disk by default")
    }

    func testStartFolder() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(startFolder(environment: "/env", recent: ["/r"], home: home), "/env")
        XCTAssertEqual(startFolder(environment: nil, recent: ["/r"], home: home, exists: { _ in true }), "/r")
        XCTAssertEqual(startFolder(environment: nil, recent: ["/gone", "/r"], home: home, exists: { $0 == "/r" }), "/r",
                       "a deleted folder is skipped")
        XCTAssertEqual(startFolder(environment: nil, recent: ["/nonexistent-\(UUID())"], home: home), "/Users/x",
                       "checks the disk by default")
        XCTAssertEqual(startFolder(environment: nil, recent: [], home: home), "/Users/x")
    }

    func testStartFolderOff() {
        let home = URL(fileURLWithPath: "/Users/x")
        let yes: (String) -> Bool = { _ in true }
        XCTAssertEqual(startFolder(environment: nil, recent: ["/r"], home: home, lastTargetMinutes: 0, exists: yes),
                       "/Users/x", "Off: not the last folder sent to")
        XCTAssertEqual(startFolder(environment: "/env", recent: ["/r"], home: home, lastTargetMinutes: 0, exists: yes),
                       "/env")
        XCTAssertEqual(startFolder(environment: nil, recent: ["/r"], home: home, lastTargetMinutes: 5, exists: yes),
                       "/r", "any other setting keeps it")
    }

    // Off, through to the target the panel starts on: the detected project,
    // else $SHOT_PROMPT_CWD, else home, never the last folder sent to.
    func testStartTargetOff() {
        let home = URL(fileURLWithPath: "/Users/x")
        let projects = [Project(title: "a", root: "/w/a"), Project(title: "r", root: "/r")]
        func start(env: String?, detected: String?, minutes: Int) -> SendTarget {
            let root = startFolder(environment: env, recent: ["/r"], home: home, lastTargetMinutes: minutes,
                                   exists: { _ in true })
            let entries = pickerEntries(projects: projects, defaultRoot: root)
            return resolveTarget(picked: nil, remembered: nil, detectedRoot: detected, entries: entries,
                                 defaultRoot: root)
        }
        XCTAssertEqual(start(env: nil, detected: nil, minutes: 0), .newThread(root: "/Users/x"))
        XCTAssertEqual(start(env: "/env", detected: nil, minutes: 0), .newThread(root: "/env"))
        XCTAssertEqual(start(env: "/env", detected: "/w/a", minutes: 0), .newThread(root: "/w/a"))
        XCTAssertEqual(start(env: nil, detected: nil, minutes: 15), .newThread(root: "/r"), "unchanged when on")
    }

    func testIsInApplicationsFolder() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertTrue(isInApplicationsFolder("/Applications/ShotPrompt.app", home: home))
        XCTAssertTrue(isInApplicationsFolder("/Users/x/Applications/ShotPrompt.app", home: home))
        XCTAssertFalse(isInApplicationsFolder("/Volumes/ShotPrompt/ShotPrompt.app", home: home), "the disk image")
        XCTAssertFalse(isInApplicationsFolder("/Users/x/Downloads/ShotPrompt.app", home: home))
        XCTAssertFalse(isInApplicationsFolder("/Applications/../tmp/ShotPrompt.app", home: home))
    }

    func testWelcomeText() {
        let codex = welcomeText(target: .codex, inApplications: true)
        XCTAssertTrue(codex.hasPrefix("Take a screenshot"))
        XCTAssertTrue(codex.contains("It goes to Codex with your screenshot."))
        XCTAssertTrue(welcomeText(target: .clipboard, inApplications: true).contains("No AI tool was found"))
        XCTAssertTrue(welcomeText(target: .codex, inApplications: false).hasPrefix("Move ShotPrompt"))
    }
}
