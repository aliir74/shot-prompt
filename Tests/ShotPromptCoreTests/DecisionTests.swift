import XCTest
@testable import ShotPromptCore

final class DecisionTests: XCTestCase {
    func testCaptureAction() {
        XCTAssertEqual(captureAction(hasText: false, editable: true), .showIcon)
        XCTAssertEqual(captureAction(hasText: false, editable: false), .showIcon)
        XCTAssertEqual(captureAction(hasText: true, editable: true), .replaceImage)
        XCTAssertEqual(captureAction(hasText: true, editable: false), .ignore, "a send is running")
        XCTAssertEqual(captureAction(hasText: false, editable: true, pasteIntoT3: true), .pasteIntoT3)
        XCTAssertEqual(captureAction(hasText: true, editable: true, pasteIntoT3: true), .replaceImage,
                       "you already chose the panel")
        XCTAssertEqual(captureAction(hasText: true, editable: false, pasteIntoT3: true), .ignore)
    }

    func key(ours: Bool = true, esc: Bool = false, cmd: Bool = false, text: Bool = false, icon: Bool = false) -> KeyAction {
        keyAction(isOurs: ours, isEscape: esc, commandOrControl: cmd, hasText: text, onIcon: icon)
    }

    func testKeyAction() {
        XCTAssertEqual(key(ours: false, esc: true), .pass, "other windows and an open menu keep their keys")
        XCTAssertEqual(key(esc: true, text: true), .dismiss, "Esc always closes")
        XCTAssertEqual(key(cmd: true), .dismiss, "Cmd+V into another app before typing")
        XCTAssertEqual(key(cmd: true, icon: true), .dismiss)
        XCTAssertEqual(key(cmd: true, text: true), .pass, "after typing, shortcuts edit the prompt")
        XCTAssertEqual(key(icon: true), .expandAndType)
        XCTAssertEqual(key(), .pass, "plain keys in the panel type")
    }

    func act(pid: Int32? = 50, bundle: String? = "com.other", returnTo: Int32? = nil, panel: Bool = false,
             icon: Bool = false, left: TimeInterval = 20) -> ActivationAction {
        activationAction(activatedPID: pid, activatedBundleID: bundle, ownPID: 1, returnToPID: returnTo,
                         panelOpen: panel, iconOpen: icon, iconTimeLeft: left)
    }

    func testActivationAction() {
        XCTAssertEqual(act(pid: 1, panel: true), .none, "this app coming forward for the picker")
        XCTAssertEqual(act(pid: 50, returnTo: 50, panel: true), .clearReturn, "the front handed back")
        XCTAssertEqual(act(pid: 51, returnTo: 50, panel: true), .dismissIfEmpty)
        XCTAssertEqual(act(pid: nil, returnTo: 50, panel: true), .dismissIfEmpty, "unknown app")
        XCTAssertEqual(act(panel: true, icon: true), .dismissIfEmpty)
        XCTAssertEqual(act(icon: true), .shortenIcon(iconAwaySeconds))
        XCTAssertEqual(act(bundle: shottrBundleID, icon: true), .none, "Shottr around a capture")
        XCTAssertEqual(act(icon: true, left: iconAwaySeconds), .none, "already leaving soon enough")
        XCTAssertEqual(act(), .none, "nothing on screen")
    }

    func testTextCommand() {
        XCTAssertEqual(textCommand("insertNewline:", hasPicker: false), .send)
        XCTAssertEqual(textCommand("cancelOperation:", hasPicker: true), .dismiss)
        XCTAssertEqual(textCommand("insertTab:", hasPicker: true), .openPicker)
        XCTAssertEqual(textCommand("insertTab:", hasPicker: false), .none)
        XCTAssertEqual(textCommand("moveUp:", hasPicker: true), .none)
    }

    func testTimings() {
        XCTAssertEqual(idleSeconds, 5)
        XCTAssertEqual(iconSeconds, 20)
        XCTAssertEqual(iconAwaySeconds, 3)
        XCTAssertEqual(maxPromptLines, 6)
    }
}
