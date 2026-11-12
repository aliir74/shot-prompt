import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotPromptCore

final class T3PasteTests: XCTestCase {
    func testIsT3() {
        XCTAssertTrue(isT3("com.t3tools.t3code"), "release and nightly")
        XCTAssertTrue(isT3("com.t3tools.t3code.dev"))
        XCTAssertFalse(isT3("com.t3tools.t3codex"))
        XCTAssertFalse(isT3("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(isT3(nil))
    }

    func testIsBystander() {
        XCTAssertTrue(isBystander(bundleID: shottrBundleID, isSelf: false))
        XCTAssertTrue(isBystander(bundleID: nil, isSelf: true), "this app, run unbundled")
        XCTAssertFalse(isBystander(bundleID: t3BundleID, isSelf: false))
        XCTAssertFalse(isBystander(bundleID: nil, isSelf: false))
    }

    func testCapturedApp() {
        let shottr = { (app: String) in app == "shottr" }
        XCTAssertEqual(capturedApp(front: "t3", previous: "slack", isBystander: shottr), "t3")
        XCTAssertEqual(capturedApp(front: "shottr", previous: "t3", isBystander: shottr), "t3",
                       "Shottr in front for the capture")
        XCTAssertNil(capturedApp(front: "shottr", previous: nil, isBystander: shottr))
        XCTAssertEqual(capturedApp(front: nil, previous: "t3", isBystander: shottr), "t3")
    }

    func testPastesIntoT3() {
        XCTAssertTrue(pastesIntoT3(enabled: true, capturedBundleID: t3BundleID))
        XCTAssertFalse(pastesIntoT3(enabled: false, capturedBundleID: t3BundleID), "setting off")
        XCTAssertFalse(pastesIntoT3(enabled: true, capturedBundleID: "com.apple.Safari"))
        XCTAssertFalse(pastesIntoT3(enabled: true, capturedBundleID: nil))
    }

    func testBreaksLineBeforePaste() {
        XCTAssertTrue(breaksLineBeforePaste(text: "look at this", caret: 12), "caret after text")
        XCTAssertTrue(breaksLineBeforePaste(text: "look at this", caret: nil), "caret unknown counts as the end")
        XCTAssertTrue(breaksLineBeforePaste(text: "ab", caret: 99), "caret past the end")
        XCTAssertTrue(breaksLineBeforePaste(text: "first\nsecond", caret: 8), "mid line")
        XCTAssertFalse(breaksLineBeforePaste(text: "first\n", caret: 6), "already on a new line")
        XCTAssertFalse(breaksLineBeforePaste(text: "look", caret: 0), "caret at the start")
        XCTAssertFalse(breaksLineBeforePaste(text: "look", caret: -1))
        XCTAssertFalse(breaksLineBeforePaste(text: "", caret: 0), "empty composer")
        XCTAssertFalse(breaksLineBeforePaste(text: nil, caret: nil), "text unreadable")
        XCTAssertTrue(breaksLineBeforePaste(text: "تست 👀", caret: 6), "UTF-16 caret after an emoji")
    }

    func testSettingKey() {
        XCTAssertEqual(pasteIntoT3Key, "pasteIntoT3")
    }

    func testIsComposer() {
        XCTAssertTrue(isComposer(role: "AXTextArea", classes: ["tiptap", "ProseMirror", "composer-tiptap"]))
        XCTAssertFalse(isComposer(role: "AXTextArea", classes: ["ProseMirror"]), "another editor")
        XCTAssertFalse(isComposer(role: nil, classes: ["composer-tiptap"]))
        var read = false
        XCTAssertFalse(isComposer(role: "AXGroup", classes: { read = true; return ["composer-tiptap"] }()))
        XCTAssertFalse(read, "classes are not read for a node that is not a text area")
    }

    // A tree as [node: children]; "c…" nodes are composers, "*" marks focus.
    let tree: [String: [String]] = [
        "window": ["timeline", "side"],
        "timeline": ["html", "c-main"],
        "side": ["c-side*"],
        "html": ["field"],
    ]

    func find(_ roots: [String], in tree: [String: [String]], limit: Int = 100) -> String? {
        findComposer(roots: roots, limit: limit, children: { tree[$0] ?? [] },
                     isComposer: { $0.hasPrefix("c-") }, isFocused: { $0.hasSuffix("*") })
    }

    func testFindComposer() {
        XCTAssertEqual(find(["window"], in: tree), "c-side*", "the composer you were typing in")
        var unfocused = tree
        unfocused["side"] = ["c-side"]
        XCTAssertEqual(find(["window"], in: unfocused), "c-main", "else the first one")
        XCTAssertNil(find(["window"], in: ["window": ["timeline"]]), "no chat open")
        XCTAssertNil(find([], in: tree))
        XCTAssertNil(find(["window"], in: tree, limit: 3), "the walk stops at the limit")
    }

    func writeImage(_ type: UTType, to url: URL) {
        let ctx = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func size(of data: Data) -> (type: String?, width: Int?) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return (CGImageSourceGetType(src) as String?, props?[kCGImagePropertyPixelWidth] as? Int)
    }

    func testPngDataKeepsAPng() throws {
        let url = try makeTempDir(self).appendingPathComponent("SCR-1.png")
        writeImage(.png, to: url)
        XCTAssertEqual(pngData(of: url), try Data(contentsOf: url), "the file's own bytes")
    }

    func testPngDataReencodesAJpeg() throws {
        let url = try makeTempDir(self).appendingPathComponent("SCR-1.jpeg")
        writeImage(.jpeg, to: url)
        let data = try XCTUnwrap(pngData(of: url))
        let info = size(of: data)
        XCTAssertEqual(info.type, UTType.png.identifier)
        XCTAssertEqual(info.width, 4)
    }

    func testPngDataOfNoImage() throws {
        let url = try makeTempDir(self).appendingPathComponent("SCR-1.png")
        FileManager.default.createFile(atPath: url.path, contents: Data("not an image".utf8))
        XCTAssertNil(pngData(of: url))
        XCTAssertNil(pngData(of: url.deletingLastPathComponent().appendingPathComponent("missing.png")))
    }

    func testPasteTimings() {
        XCTAssertEqual(pasteWaitSeconds, 1.5)
        XCTAssertEqual(pastePollSeconds, 0.1)
        XCTAssertEqual(composerSearchLimit, 20_000)
    }
}
