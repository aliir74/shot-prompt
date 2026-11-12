import Foundation

public let shottrBundleID = "cc.ffitch.shottr"

// What a new capture does to what is on screen.
public enum CaptureAction: Equatable {
    // A send is running: the sent screenshot stays.
    case ignore
    // You have typed: swap the screenshot, keep the prompt.
    case replaceImage
    // Nothing typed: drop what is there and show the icon for the new capture.
    case showIcon
    // Nothing typed, and the capture was taken in T3 with the paste setting on:
    // drop what is there and paste the capture into T3's open chat.
    case pasteIntoT3
}

// Text in the panel means you already chose the panel, so a new capture swaps
// its screenshot even when it was taken in T3.
public func captureAction(hasText: Bool, editable: Bool, pasteIntoT3: Bool = false) -> CaptureAction {
    guard hasText else { return pasteIntoT3 ? .pasteIntoT3 : .showIcon }
    return editable ? .replaceImage : .ignore
}

public enum KeyAction: Equatable {
    // Let the key through to its window.
    case pass
    case dismiss
    // Open the prompt and type the key into it.
    case expandAndType
}

// Esc closes. On the icon, Cmd/Ctrl (Cmd+V into another app) means the
// capture was meant for something else: get out of the way. Any other key on
// the icon opens the prompt and becomes its first character. In the open
// panel, Cmd/Ctrl shortcuts edit the prompt (Cmd+V, Cmd+A), even before any
// typing. Keys for other windows, or while the picker menu is open, pass.
public func keyAction(isOurs: Bool, isEscape: Bool, commandOrControl: Bool, onIcon: Bool) -> KeyAction {
    guard isOurs else { return .pass }
    if isEscape { return .dismiss }
    guard onIcon else { return .pass }
    return commandOrControl ? .dismiss : .expandAndType
}

// The standard edit shortcuts. This app has no menu bar, which is what maps
// them to actions in other apps, so the panel maps them itself. A non-Latin
// layout (Persian) can report its own letter, so the key's position decides then.
public func editCommand(characters: String?, keyCode: UInt16, command: Bool, shift: Bool,
                        option: Bool, control: Bool) -> String? {
    guard command, !option, !control else { return nil }
    let positions: [UInt16: String] = [0: "a", 8: "c", 9: "v", 7: "x", 6: "z"]
    var key = characters?.lowercased() ?? ""
    if !(key.count == 1 && key.first!.isASCII && key.first!.isLetter) { key = positions[keyCode] ?? "" }
    switch (key, shift) {
    case ("a", false): return "selectAll:"
    case ("c", false): return "copy:"
    case ("v", false): return "paste:"
    case ("x", false): return "cut:"
    case ("z", false): return "undo:"
    case ("z", true): return "redo:"
    default: return nil
    }
}

// The Fn (globe) key, which dictation apps such as Wispr Flow hold while you talk.
public let fnKeyCode: UInt16 = 63

public enum FnAction: Equatable {
    case none
    // Fn went down: hold the panel open while you talk.
    case hold
    // Fn went down on the icon: open the prompt for the words to land in, and hold it.
    case expandAndHold
    // Fn came up: the words arrive a moment later, so hold a while longer.
    case release
}

public func fnAction(keyCode: UInt16, fnDown: Bool, onIcon: Bool) -> FnAction {
    guard keyCode == fnKeyCode else { return .none }
    guard fnDown else { return .release }
    return onIcon ? .expandAndHold : .hold
}

// Dictation apps whose microphone use means you are talking to the prompt.
// This covers any hotkey and hands-free mode, where Fn is not held.
public let dictationBundlePrefixes = ["com.electron.wispr-flow"]

public func isDictationApp(bundleID: String?) -> Bool {
    guard let b = bundleID else { return false }
    return dictationBundlePrefixes.contains { b.hasPrefix($0) }
}

// A dictation app took the microphone while only the icon is up: open the
// prompt, so the words land in it instead of dismissing the icon.
public func expandsForDictation(micLive: Bool, onIcon: Bool) -> Bool {
    micLive && onIcon
}

// While dictation is active (Fn held, or a dictation app has the microphone),
// and for a grace period after it ends, an empty prompt is waiting for the
// words, so nothing closes it.
public func dictationHolds(active: Bool, endedAt: Date?, now: Date) -> Bool {
    if active { return true }
    guard let e = endedAt else { return false }
    return now.timeIntervalSince(e) < dictationGraceSeconds
}

public enum ActivationAction: Equatable {
    case none
    // The app the picker handed the front back to is in front again.
    case clearReturn
    // The panel is open: close it if nothing is typed.
    case dismissIfEmpty
    // Only the icon is up: let it leave after this many seconds.
    case shortenIcon(TimeInterval)
}

// Switching apps before typing means the capture was not for Claude, so an
// empty prompt closes and the icon leaves soon after, unless you are dictating. This app coming forward
// for the picker, the picker handing the front back, and Shottr coming forward
// around a capture are not switches.
public func activationAction(activatedPID: Int32?, activatedBundleID: String?, ownPID: Int32,
                             returnToPID: Int32?, panelOpen: Bool, iconOpen: Bool,
                             iconTimeLeft: TimeInterval, dictating: Bool = false) -> ActivationAction {
    if activatedPID == ownPID || dictating { return .none }
    if let r = returnToPID, activatedPID == r { return .clearReturn }
    if panelOpen { return .dismissIfEmpty }
    guard iconOpen, activatedBundleID != shottrBundleID, iconTimeLeft > iconAwaySeconds else { return .none }
    return .shortenIcon(iconAwaySeconds)
}

public enum TextCommand: Equatable {
    case send, dismiss, openPicker, none
}

// Enter sends, Esc closes, Tab opens the picker when there is one.
public func textCommand(_ selector: String, hasPicker: Bool) -> TextCommand {
    switch selector {
    case "insertNewline:": return .send
    case "cancelOperation:": return .dismiss
    case "insertTab:": return hasPicker ? .openPicker : .none
    default: return .none
    }
}
