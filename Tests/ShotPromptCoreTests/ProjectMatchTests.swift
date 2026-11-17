import CoreGraphics
import XCTest
@testable import ShotPromptCore

final class ProjectMatchTests: XCTestCase {
    let projects = [
        Project(title: "Vault26", root: "/Users/a/Vault26"),
        Project(title: "shot-prompt", root: "/Users/a/Coding/personal/shot-prompt"),
        Project(title: "Platform", root: "/Users/a/Coding/ovou-platform"),
        Project(title: "Front", root: "/Users/a/Coding/ovou-platform/front-v2"),
        Project(title: "api", root: "/Users/a/Coding/api"),
        Project(title: "api", root: "/Users/a/Other/api"),
    ]

    func match(_ w: WindowInfo, server: String? = nil) -> String? {
        matchProject(w, serverFolder: server, projects: projects, home: "/Users/a")
    }

    func testPaths() {
        // The window's file, the longest root holding it.
        XCTAssertEqual(match(WindowInfo(document: "file:///Users/a/Coding/ovou-platform/front-v2/src/App.tsx")),
                       "/Users/a/Coding/ovou-platform/front-v2")
        XCTAssertEqual(match(WindowInfo(document: "file:///Users/a/Coding/ovou-platform/README.md")),
                       "/Users/a/Coding/ovou-platform")
        // A path in a terminal title, with ~ and after a colon.
        XCTAssertEqual(match(WindowInfo(title: "a@mac:~/Vault26/Projects")), "/Users/a/Vault26")
        XCTAssertEqual(match(WindowInfo(title: "vim /Users/a/Coding/personal/shot-prompt/x.swift")),
                       "/Users/a/Coding/personal/shot-prompt")
        // A bare ~ is the home folder, which holds no project root.
        XCTAssertNil(match(WindowInfo(title: "zsh ~")))
        // A T3 worktree counts as its project.
        XCTAssertEqual(match(WindowInfo(title: "~/.t3/worktrees/shot-prompt/t3-1234")),
                       "/Users/a/Coding/personal/shot-prompt")
        XCTAssertNil(match(WindowInfo(title: "~/.t3/worktrees")))
        // The localhost server's folder.
        XCTAssertEqual(match(WindowInfo(), server: "/Users/a/Coding/ovou-platform/front-v2"),
                       "/Users/a/Coding/ovou-platform/front-v2")
        // Two projects named by paths: cannot tell, and later steps do not run.
        XCTAssertNil(match(WindowInfo(title: "diff /Users/a/Vault26 /Users/a/Coding/api — shot-prompt")))
        // A path in no project falls through to the title.
        XCTAssertEqual(match(WindowInfo(title: "/tmp/x — shot-prompt")), "/Users/a/Coding/personal/shot-prompt")
    }

    func testRepo() {
        XCTAssertEqual(match(WindowInfo(document: "https://github.com/aliir74/shot-prompt/pull/14")),
                       "/Users/a/Coding/personal/shot-prompt")
        XCTAssertEqual(match(WindowInfo(webURL: "https://gitlab.com/ovou/ovou-platform.git")),
                       "/Users/a/Coding/ovou-platform")
        // GitLab subgroups: the repository is the last part before "/-/".
        XCTAssertEqual(match(WindowInfo(document: "https://gitlab.com/ovou/vault26/shot-prompt/-/issues/1")),
                       "/Users/a/Coding/personal/shot-prompt")
        XCTAssertEqual(match(WindowInfo(document: "https://gitlab.com/ovou/team/shot-prompt")),
                       "/Users/a/Coding/personal/shot-prompt")
        XCTAssertNil(match(WindowInfo(document: "https://gitlab.com/ovou/-/issues")))
        // Two folders share the name.
        XCTAssertNil(match(WindowInfo(document: "https://github.com/x/api")))
        XCTAssertNil(match(WindowInfo(document: "https://github.com/aliir74")))
        XCTAssertNil(match(WindowInfo(document: "https://example.com/aliir74/shot-prompt")))
    }

    func testTitle() {
        XCTAssertEqual(match(WindowInfo(title: "Config.swift — shot-prompt")), "/Users/a/Coding/personal/shot-prompt")
        XCTAssertEqual(match(WindowInfo(title: "vault26 / Brief me on the email")), "/Users/a/Vault26")
        // The T3 title, not only the folder name.
        XCTAssertEqual(match(WindowInfo(title: "Front · dashboard")), "/Users/a/Coding/ovou-platform/front-v2")
        XCTAssertNil(match(WindowInfo(title: "Inbox - Gmail")))
        XCTAssertNil(match(WindowInfo(title: "api - docs")))
        XCTAssertNil(match(WindowInfo()))
    }

    func testLocalPortAndLsof() {
        XCTAssertEqual(localPort("http://localhost:3000/x"), 3000)
        XCTAssertEqual(localPort("http://127.0.0.1:8000"), 8000)
        XCTAssertEqual(localPort("http://[::1]:5173/"), 5173)
        XCTAssertNil(localPort("http://localhost/"))
        XCTAssertNil(localPort("https://github.com:443/"))
        XCTAssertNil(localPort("nope"))
        XCTAssertNil(localPort(nil))
        XCTAssertEqual(lsofField("p123\nf4\nn*:3000\n", "p"), "123")
        XCTAssertEqual(lsofField("p9\nfcwd\nn/Users/a/x\n", "n"), "/Users/a/x")
        XCTAssertNil(lsofField("p\n", "p"))
        XCTAssertNil(lsofField("", "n"))
    }

    func testChipLayout() {
        XCTAssertEqual(chipLayout(widths: [], x: 10, maxX: 300), ChipLayout(frames: [], height: 0))
        let l = chipLayout(widths: [60.2, 400, 100], x: 10, maxX: 300)
        XCTAssertEqual(l.frames, [
            CGRect(x: 10, y: 0, width: 61, height: 18),
            CGRect(x: 75, y: 0, width: 150, height: 18),
            CGRect(x: 10, y: 22, width: 100, height: 18),
        ])
        XCTAssertEqual(l.height, 46)
        // A chip never runs past maxX, even alone on its row.
        XCTAssertEqual(chipLayout(widths: [500], x: 0, maxX: 100).frames, [CGRect(x: 0, y: 0, width: 100, height: 18)])
        XCTAssertEqual(fitPrompt(usedHeight: 0, lineHeight: 18, maxLines: 6, chips: 46).panelHeight, 130)
    }
}
