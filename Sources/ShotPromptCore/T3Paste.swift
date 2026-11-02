import Foundation
import ImageIO
import UniformTypeIdentifiers

// The "paste into T3" setting: with it on, a capture taken while T3 Code is
// the app in use goes straight into the chat open there, as if you pressed
// Cmd+V in it, and no icon or prompt panel shows. Turn it on with
// `defaults write io.github.aliir74.shot-prompt pasteIntoT3 -bool true`;
// it is read at every capture, so no restart is needed.
public let pasteIntoT3Key = "pasteIntoT3"

// T3 Code's release and nightly builds share this bundle ID; dev builds add ".dev".
public let t3BundleID = "com.t3tools.t3code"

public func isT3(_ bundleID: String?) -> Bool {
    guard let id = bundleID else { return false }
    return id == t3BundleID || id.hasPrefix(t3BundleID + ".")
}

// Shottr comes forward around a capture, and this app for the picker. Neither
// is the app the capture was taken in.
public func isBystander(bundleID: String?, isSelf: Bool) -> Bool {
    isSelf || bundleID == shottrBundleID
}

// The app the capture was taken in: the front app, or the last other app to
// come forward when the front one is a bystander.
public func capturedApp<App>(front: App?, previous: App?, isBystander: (App) -> Bool) -> App? {
    guard let f = front, !isBystander(f) else { return previous }
    return f
}

public func pastesIntoT3(enabled: Bool, capturedBundleID: String?) -> Bool {
    enabled && isT3(capturedBundleID)
}

// T3's chat composer, as its accessibility tree shows it: a Tiptap editor.
public let composerRole = "AXTextArea"
public let composerClass = "composer-tiptap"

// Each attribute is a round trip to T3, so the classes are read only for a text area.
public func isComposer(role: String?, classes: @autoclosure () -> [String]) -> Bool {
    role == composerRole && classes().contains(composerClass)
}

// Walks a tree breadth first, visiting at most `limit` nodes, and returns the
// focused composer, else the first one: a side chat has a composer of its own,
// and the one you were typing in is the chat you mean.
public func findComposer<Node>(roots: [Node], limit: Int, children: (Node) -> [Node],
                               isComposer: (Node) -> Bool, isFocused: (Node) -> Bool) -> Node? {
    var queue = ArraySlice(roots)
    var first: Node?
    var visited = 0
    while let node = queue.popFirst(), visited < limit {
        visited += 1
        if isComposer(node) {
            if isFocused(node) { return node }
            if first == nil { first = node }
        }
        queue.append(contentsOf: children(node))
    }
    return first
}

// The capture as PNG bytes for the pasteboard, since T3 takes a pasted image
// as a PNG file. A PNG goes as it is; a JPEG (Shottr's "Auto" format for
// photo-heavy captures) is re-encoded. Nil when the file is not an image.
public func pngData(of url: URL) -> Data? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    if CGImageSourceGetType(source) as String? == UTType.png.identifier {
        return try? Data(contentsOf: url)
    }
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

// How long the paste waits for T3 to come forward (Shottr can still be in
// front) and for its accessibility tree to show the composer, which Electron
// builds only once it is asked for.
public let pasteWaitSeconds: TimeInterval = 1.5
public let pastePollSeconds: TimeInterval = 0.1
// The composer is near the top of T3's tree (about 800 nodes with a long chat
// open); the cap only bounds a walk through a tree that has none.
public let composerSearchLimit = 20_000
