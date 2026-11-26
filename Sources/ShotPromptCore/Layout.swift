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
// past that it scrolls. `chips` is the height of the context chips under it.
public func fitPrompt(usedHeight: CGFloat, lineHeight: CGFloat, maxLines: CGFloat,
                      chips: CGFloat = 0) -> PromptFit {
    let line = ceil(lineHeight), used = ceil(usedHeight), cap = line * maxLines
    let h = min(max(used, line), cap)
    let height = max(PanelMetrics.minHeight, PanelMetrics.bottom + chips + h + PanelMetrics.top)
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

public enum PopupMetrics {
    public static let rowHeight: CGFloat = 24
    public static let headerHeight: CGFloat = 22
    public static let searchHeight: CGFloat = 34
    // Fits 2 headers and 15 items, the unfiltered list, without scrolling.
    public static let maxListHeight: CGFloat = 420
    public static let padding: CGFloat = 8
    // Space between the panel and the popup.
    public static let gap: CGFloat = 4
}

// The search field, the rows (scrolling past maxListHeight) and padding.
public func popupHeight(_ rows: [PopupRow]) -> CGFloat {
    let list = rows.reduce(CGFloat(0)) { sum, row in
        if case .header = row { return sum + PopupMetrics.headerHeight }
        return sum + PopupMetrics.rowHeight
    }
    return PopupMetrics.searchHeight + min(list, PopupMetrics.maxListHeight) + PopupMetrics.padding
}

// The popup hangs under the panel, as wide as it; above it when there is no
// room below; always kept on the screen.
public func popupFrame(panel: CGRect, height: CGFloat, visible: CGRect) -> CGRect {
    var y = panel.minY - PopupMetrics.gap - height
    if y < visible.minY + 8 { y = panel.maxY + PopupMetrics.gap }
    let size = CGSize(width: panel.width, height: height)
    return CGRect(origin: clamp(origin: CGPoint(x: panel.minX, y: y), size: size, in: visible), size: size)
}

public enum TargetChipMetrics {
    public static let height: CGFloat = 20
    // Room around the label inside the chip.
    public static let padding: CGFloat = 16
    public static let minWidth: CGFloat = 60
    // Space between the hint and the chip.
    public static let gap: CGFloat = 8
}

public struct TargetLayout: Equatable {
    public let chipFrame: CGRect
    public let hintWidth: CGFloat
}

// The target chip sits at the right edge of the status row, as wide as its
// label; the hint keeps its full width first, so a long message shrinks the
// chip, down to minWidth. The hint gets what is left, never less than 0.
public func targetLayout(containerWidth: CGFloat, labelWidth: CGFloat, hintMinX: CGFloat,
                         hintWidth: CGFloat) -> TargetLayout {
    let right = containerWidth - 12
    let want = ceil(labelWidth) + TargetChipMetrics.padding
    let room = right - hintMinX - ceil(hintWidth) - TargetChipMetrics.gap
    let w = min(want, max(room, TargetChipMetrics.minWidth))
    return TargetLayout(chipFrame: CGRect(x: right - w, y: 9, width: w, height: TargetChipMetrics.height),
                        hintWidth: max(right - w - hintMinX - TargetChipMetrics.gap, 0))
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

public enum ChipMetrics {
    public static let height: CGFloat = 18
    public static let gap: CGFloat = 4
    // A long window title is cut to this width; its tooltip has all of it.
    public static let maxWidth: CGFloat = 150
}

public struct ChipLayout: Equatable {
    // Each chip's frame, with y counted down from the top of the chip area.
    public let frames: [CGRect]
    // The chip area's height, a gap under the prompt included; 0 with no chips.
    public let height: CGFloat
}

// Chips flow left to right from x, wrapping onto a new row at maxX. Each is
// as wide as its content, at most ChipMetrics.maxWidth.
public func chipLayout(widths: [CGFloat], x: CGFloat, maxX: CGFloat) -> ChipLayout {
    var frames: [CGRect] = []
    var cx = x, row: CGFloat = 0
    for raw in widths {
        let w = min(ceil(raw), ChipMetrics.maxWidth, maxX - x)
        if cx > x && cx + w > maxX { cx = x; row += 1 }
        frames.append(CGRect(x: cx, y: row * (ChipMetrics.height + ChipMetrics.gap), width: w, height: ChipMetrics.height))
        cx += w + ChipMetrics.gap
    }
    let height = frames.isEmpty ? 0 : (row + 1) * (ChipMetrics.height + ChipMetrics.gap) + 2
    return ChipLayout(frames: frames, height: height)
}
