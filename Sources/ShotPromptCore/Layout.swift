import CoreGraphics
import Foundation

// Keeps a window of this size inside the visible screen, margin points from each edge.
public func clamp(origin: CGPoint, size: CGSize, in visible: CGRect, margin: CGFloat = 8) -> CGPoint {
    CGPoint(x: min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin),
            y: min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin))
}

public let iconSize: CGFloat = 56

// The mouse is where the capture region ended; the icon sits just past it.
public func iconOrigin(mouse: CGPoint, visible: CGRect) -> CGPoint {
    clamp(origin: CGPoint(x: mouse.x + 8, y: mouse.y - iconSize - 8),
          size: CGSize(width: iconSize, height: iconSize), in: visible)
}

public enum PanelMetrics {
    public static let width: CGFloat = 420
    public static let thumb: CGFloat = 64
    // Space above the prompt (the transparent title bar) and below it (the status row).
    public static let top: CGFloat = 24
    public static let bottom: CGFloat = 42
    public static let minHeight: CGFloat = thumb + 20
}

// The panel opens with its top edge where the icon's top edge was.
public func panelOrigin(iconFrame: CGRect, panelHeight: CGFloat, visible: CGRect) -> CGPoint {
    clamp(origin: CGPoint(x: iconFrame.minX, y: iconFrame.maxY - panelHeight),
          size: CGSize(width: PanelMetrics.width, height: panelHeight), in: visible)
}

public struct PromptFit: Equatable {
    // The prompt's height.
    public let height: CGFloat
    // Past the line cap: show a scroller and let the view scroll.
    public let scrolls: Bool
    // The panel's height for that prompt.
    public let panelHeight: CGFloat
}

// The prompt grows to fit the text, at least one line and at most maxLines;
// past that it scrolls.
public func fitPrompt(usedHeight: CGFloat, lineHeight: CGFloat, maxLines: CGFloat) -> PromptFit {
    let line = ceil(lineHeight), used = ceil(usedHeight), cap = line * maxLines
    let h = min(max(used, line), cap)
    let height = max(PanelMetrics.minHeight, PanelMetrics.bottom + h + PanelMetrics.top)
    return PromptFit(height: h, scrolls: used > cap, panelHeight: height)
}

// The panel grows downward from its top edge, but not below the visible screen.
public func grownFrame(_ frame: CGRect, height: CGFloat, visible: CGRect?) -> CGRect {
    var f = frame
    f.origin.y = frame.maxY - height
    f.size.height = height
    if let vis = visible, f.minY < vis.minY + 8 { f.origin.y = vis.minY + 8 }
    return f
}

public struct StatusLayout: Equatable {
    public let pickerFrame: CGRect
    public let hintWidth: CGFloat
}

// The picker sits at the right edge, as wide as the chosen title (at most 200);
// the hint label takes the rest.
public func statusLayout(containerWidth: CGFloat, titleWidth: CGFloat, hintMinX: CGFloat) -> StatusLayout {
    let right = containerWidth - 12
    let pw = min(ceil(titleWidth) + 26, 200)
    return StatusLayout(pickerFrame: CGRect(x: right - pw + 6, y: 8, width: pw, height: 22),
                        hintWidth: max(right - pw - hintMinX - 4, 0))
}

public struct Fade: Equatable {
    // Fade the top edge: text is hidden above.
    public let top: Bool
    // Fade the bottom edge: text is hidden below.
    public let bottom: Bool
    // How far in from each edge the fade reaches, as a fraction of the height.
    public let edge: Double
}

// Once the prompt scrolls, the text fades into whichever edge hides more.
public func fade(visible: CGRect, documentHeight: CGFloat, scrolls: Bool) -> Fade {
    Fade(top: scrolls && visible.minY > 0.5,
         bottom: scrolls && visible.maxY < documentHeight - 0.5,
         edge: Double(min(24 / max(visible.height, 1), 0.5)))
}
