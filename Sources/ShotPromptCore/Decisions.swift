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
}

public func captureAction(hasText: Bool, editable: Bool) -> CaptureAction {
    guard hasText else { return .showIcon }
    return editable ? .replaceImage : .ignore
}

public enum KeyAction: Equatable {
    // Let the key through to its window.
    case pass
    case dismiss
    // Open the prompt and type the key into it.
    case expandAndType
}

// Esc, or Cmd/Ctrl (Cmd+V into another app) before any typing, means the
// capture was meant for something else: get out of the way. Any other key on
// the icon opens the prompt and becomes its first character. Keys for other
// windows, or while the picker menu is open, pass.
public func keyAction(isOurs: Bool, isEscape: Bool, commandOrControl: Bool,
                      hasText: Bool, onIcon: Bool) -> KeyAction {
    guard isOurs else { return .pass }
    if isEscape { return .dismiss }
    if commandOrControl && !hasText { return .dismiss }
    return onIcon ? .expandAndType : .pass
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
// empty prompt closes and the icon leaves soon after. This app coming forward
// for the picker, the picker handing the front back, and Shottr coming forward
// around a capture are not switches.
public func activationAction(activatedPID: Int32?, activatedBundleID: String?, ownPID: Int32,
                             returnToPID: Int32?, panelOpen: Bool, iconOpen: Bool,
                             iconTimeLeft: TimeInterval) -> ActivationAction {
    if activatedPID == ownPID { return .none }
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
