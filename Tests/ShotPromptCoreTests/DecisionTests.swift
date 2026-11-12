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

    func key(ours: Bool = true, esc: Bool = false, cmd: Bool = false, icon: Bool = false) -> KeyAction {
        keyAction(isOurs: ours, isEscape: esc, commandOrControl: cmd, onIcon: icon)
    }

    func testKeyAction() {
        XCTAssertEqual(key(ours: false, esc: true), .pass, "other windows and an open menu keep their keys")
        XCTAssertEqual(key(esc: true), .dismiss, "Esc always closes")
        XCTAssertEqual(key(esc: true, icon: true), .dismiss)
        XCTAssertEqual(key(cmd: true, icon: true), .dismiss, "Cmd+V into another app")
        XCTAssertEqual(key(cmd: true), .pass, "in the panel, shortcuts edit the prompt even when empty")
        XCTAssertEqual(key(icon: true), .expandAndType)
        XCTAssertEqual(key(), .pass, "plain keys in the panel type")
    }

    func edit(_ chars: String?, _ code: UInt16 = 99, cmd: Bool = true, shift: Bool = false,
              option: Bool = false, control: Bool = false) -> String? {
        editCommand(characters: chars, keyCode: code, command: cmd, shift: shift, option: option, control: control)
    }

    func testEditCommand() {
        XCTAssertEqual(edit("a"), "selectAll:")
        XCTAssertEqual(edit("c"), "copy:")
        XCTAssertEqual(edit("V"), "paste:")
        XCTAssertEqual(edit("x"), "cut:")
        XCTAssertEqual(edit("z"), "undo:")
        XCTAssertEqual(edit("z", shift: true), "redo:")
        XCTAssertNil(edit("a", shift: true))
        XCTAssertNil(edit("q"))
        XCTAssertNil(edit("v", cmd: false))
        XCTAssertNil(edit("v", option: true))
        XCTAssertNil(edit("v", control: true))
        XCTAssertEqual(edit("ر", 9), "paste:", "Persian layout: the V key by position")
        XCTAssertEqual(edit("ش", 0), "selectAll:")
        XCTAssertEqual(edit(nil, 8), "copy:")
        XCTAssertEqual(edit("ab", 7), "cut:")
        XCTAssertEqual(edit("1", 6), "undo:")
        XCTAssertNil(edit("ش", 99), "an unknown key")
    }

    func testFnAction() {
        XCTAssertEqual(fnAction(keyCode: 56, fnDown: true, onIcon: true), .none, "Shift is not Fn")
        XCTAssertEqual(fnAction(keyCode: fnKeyCode, fnDown: true, onIcon: false), .hold)
        XCTAssertEqual(fnAction(keyCode: fnKeyCode, fnDown: true, onIcon: true), .expandAndHold)
        XCTAssertEqual(fnAction(keyCode: fnKeyCode, fnDown: false, onIcon: false), .release)
    }

    func testDictationHolds() {
        let now = Date()
        XCTAssertTrue(dictationHolds(active: true, endedAt: nil, now: now))
        XCTAssertFalse(dictationHolds(active: false, endedAt: nil, now: now))
        XCTAssertTrue(dictationHolds(active: false, endedAt: now.addingTimeInterval(-2), now: now),
                      "the words arrive after dictation ends")
        XCTAssertFalse(dictationHolds(active: false, endedAt: now.addingTimeInterval(-dictationGraceSeconds),
                                      now: now))
    }

    func testDictationApps() {
        XCTAssertTrue(isDictationApp(bundleID: "com.electron.wispr-flow"))
        XCTAssertTrue(isDictationApp(bundleID: "com.electron.wispr-flow.helper"), "its audio helper holds the mic")
        XCTAssertFalse(isDictationApp(bundleID: "us.zoom.xos"), "a call is not dictation")
        XCTAssertFalse(isDictationApp(bundleID: nil))
        XCTAssertTrue(expandsForDictation(micLive: true, onIcon: true))
        XCTAssertFalse(expandsForDictation(micLive: true, onIcon: false), "the panel is already open")
        XCTAssertFalse(expandsForDictation(micLive: false, onIcon: true))
    }

    func act(pid: Int32? = 50, bundle: String? = "com.other", returnTo: Int32? = nil, panel: Bool = false,
             icon: Bool = false, left: TimeInterval = 20, dictating: Bool = false) -> ActivationAction {
        activationAction(activatedPID: pid, activatedBundleID: bundle, ownPID: 1, returnToPID: returnTo,
                         panelOpen: panel, iconOpen: icon, iconTimeLeft: left, dictating: dictating)
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
        XCTAssertEqual(act(panel: true, dictating: true), .none, "Wispr Flow coming forward while you talk")
        XCTAssertEqual(act(icon: true, dictating: true), .none)
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
        XCTAssertEqual(dictationGraceSeconds, 10)
    }
}
