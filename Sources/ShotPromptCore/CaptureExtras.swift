import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Tier 2 context: where on screen the capture was, the UI element under it,
// and a shot of the whole window it came from.

// The capture rectangle, in screen points with AppKit's bottom-left origin.
// Shottr does not say where a capture was, so it comes from the drag: the
// last mouse down and up. A drag whose size does not match the image (a
// window or fullscreen capture, which is a click or no mouse at all) gives nil.
public func captureRegion(down: CGPoint?, up: CGPoint?, upAge: TimeInterval,
                          imagePixels: CGSize, scale: CGFloat) -> CGRect? {
    guard let down, let up, upAge >= 0, upAge < captureRegionMaxAge, scale > 0 else { return nil }
    let rect = CGRect(x: min(down.x, up.x), y: min(down.y, up.y),
                      width: abs(up.x - down.x), height: abs(up.y - down.y))
    let tolerance = 2 * scale + 2
    guard rect.width >= 1, rect.height >= 1,
          abs(rect.width * scale - imagePixels.width) <= tolerance,
          abs(rect.height * scale - imagePixels.height) <= tolerance else { return nil }
    return rect
}

// Shottr writes the file a moment after the drag ends; an older drag is not this capture.
public let captureRegionMaxAge: TimeInterval = 15

// AppKit's bottom-left global coordinates to the top-left ones that
// Accessibility and the window list use; `primaryHeight` is the menu bar screen's height.
public func topLeft(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

public func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

// One accessibility node, as read for the element under a capture.
public struct ElementInfo: Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var domID: String?
    public var classes: [String]

    public init(role: String? = nil, subrole: String? = nil, title: String? = nil, label: String? = nil,
                value: String? = nil, domID: String? = nil, classes: [String] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.domID = domID
        self.classes = classes
    }

    // What names it: its title, its label, or the text of a static text.
    // A text field's value is what you typed, maybe a password, so it never counts.
    var name: String? {
        oneLine(title, limit: 60) ?? oneLine(label, limit: 60)
            ?? (role == "AXStaticText" ? oneLine(value, limit: 60) : nil)
    }

    var summary: String? {
        guard let role else { return nil }
        var parts = [role.hasPrefix("AX") ? String(role.dropFirst(2)) : role]
        if let n = name { parts.append("\u{201C}\(n)\u{201D}") }
        if let id = oneLine(domID, limit: 60) { parts.append("#" + id) }
        let cls = classes.prefix(3).compactMap { oneLine($0, limit: 40) }
        if !cls.isEmpty { parts.append("." + cls.joined(separator: ".")) }
        return parts.joined(separator: " ")
    }
}

// The element under the capture's center, then its nearest named ancestor:
// `Button “Merge” #merge-btn in Group “Checks”`. `nodes` is the hit
// element first, then its ancestors, nearest first. Nil when the hit says nothing.
public func describeElement(_ nodes: [ElementInfo]) -> String? {
    guard let hit = nodes.first, let first = hit.summary else { return nil }
    let named = nodes.dropFirst().first { $0.name != nil && $0.role != "AXWindow" && $0.role != "AXWebArea" }
    guard let parent = named?.summary else { return first }
    return first + " in " + parent
}

// The capture's rectangle inside the window shot, in its pixels (top-left
// origin). Nil when the capture is not inside the window.
public func outlineRect(region: CGRect, window: CGRect, shotPixels: CGSize) -> CGRect? {
    guard window.width > 0, window.height > 0, window.insetBy(dx: -2, dy: -2).contains(region) else { return nil }
    let sx = shotPixels.width / window.width, sy = shotPixels.height / window.height
    return CGRect(x: (region.minX - window.minX) * sx, y: (region.minY - window.minY) * sy,
                  width: region.width * sx, height: region.height * sy)
}

// A window shot adds nothing when the capture already is the whole window
// (Shottr's window capture): same size within a few pixels.
public func windowShotAdds(capturePixels: CGSize, shotPixels: CGSize) -> Bool {
    abs(capturePixels.width - shotPixels.width) > 8 || abs(capturePixels.height - shotPixels.height) > 8
}

// An image file's size in pixels, or nil when it is not an image.
public func pixelSize(of url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: w, height: h)
}

// Draws a red box (top-left origin rect, in pixels) on the image and writes
// it back as PNG. False when the image cannot be read or written.
@discardableResult
public func drawOutline(on url: URL, rect: CGRect) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    let h = CGFloat(image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let line = max(3, (h / 300).rounded())
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1))
    ctx.setLineWidth(line)
    ctx.stroke(CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        .insetBy(dx: -line / 2, dy: -line / 2))
    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, out, nil)
    return CGImageDestinationFinalize(dest)
}

// More captures you add to one prompt, after the first; past this a new one is turned away.
public let maxCaptures = 4

// The images sent, in order, and the line that tells Claude what each is.
// Nil for the line when there is only your one capture.
public func imageGuide(captures: Int, windowShot: Bool) -> String? {
    guard captures > 1 || windowShot else { return nil }
    var parts = ["1 is your capture"]
    var next = 2
    if windowShot {
        parts.append("2 is the whole window it was taken in, the capture outlined in red")
        next = 3
    }
    if captures > 1 {
        let last = next + captures - 2
        parts.append(last == next ? "\(next) is another capture" : "\(next) to \(last) are more captures, in the order taken")
    }
    return "Images: " + parts.joined(separator: "; ") + "."
}

// A window from CGWindowListCopyWindowInfo, front to back, top-left bounds.
public struct ListedWindow: Equatable {
    public let id: Int
    public let pid: Int32
    public let layer: Int
    public let bounds: CGRect

    public init(id: Int, pid: Int32, layer: Int, bounds: CGRect) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

// The captured app's window to shoot: its frontmost normal window holding
// the capture's center, else its frontmost normal window.
public func pickWindow(_ windows: [ListedWindow], pid: Int32, at point: CGPoint?) -> ListedWindow? {
    let own = windows.filter { $0.pid == pid && $0.layer == 0 }
    if let p = point, let hit = own.first(where: { $0.bounds.contains(p) }) { return hit }
    return own.first
}
