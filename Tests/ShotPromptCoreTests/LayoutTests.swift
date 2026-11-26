import CoreGraphics
import XCTest
@testable import ShotPromptCore

final class LayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testClamp() {
        let size = CGSize(width: 100, height: 50)
        XCTAssertEqual(clamp(origin: CGPoint(x: 300, y: 300), size: size, in: screen), CGPoint(x: 300, y: 300))
        XCTAssertEqual(clamp(origin: CGPoint(x: -20, y: -20), size: size, in: screen), CGPoint(x: 8, y: 8))
        XCTAssertEqual(clamp(origin: CGPoint(x: 990, y: 790), size: size, in: screen), CGPoint(x: 892, y: 742))
        let second = CGRect(x: 1000, y: 100, width: 500, height: 400)
        XCTAssertEqual(clamp(origin: CGPoint(x: 0, y: 0), size: size, in: second, margin: 0), CGPoint(x: 1000, y: 100))
    }

    func testIconOrigin() {
        XCTAssertEqual(iconOrigin(mouse: CGPoint(x: 400, y: 400), visible: screen), CGPoint(x: 408, y: 336))
        // At the bottom right corner it stays on screen.
        XCTAssertEqual(iconOrigin(mouse: CGPoint(x: 999, y: 1), visible: screen), CGPoint(x: 936, y: 8))
    }

    func testPanelOrigin() {
        let icon = CGRect(x: 408, y: 336, width: 56, height: 56)
        XCTAssertEqual(panelOrigin(iconFrame: icon, panelHeight: 84, visible: screen), CGPoint(x: 408, y: 308))
        let corner = CGRect(x: 936, y: 8, width: 56, height: 56)
        XCTAssertEqual(panelOrigin(iconFrame: corner, panelHeight: 84, visible: screen), CGPoint(x: 572, y: 8))
        XCTAssertEqual(PanelMetrics.width, 420)
        XCTAssertEqual(PanelMetrics.minHeight, 84)
    }

    func testFitPrompt() {
        // Empty prompt: one line, panel at its minimum.
        XCTAssertEqual(fitPrompt(usedHeight: 0, lineHeight: 17.6, maxLines: 6),
                       PromptFit(height: 18, scrolls: false, panelHeight: 84))
        // Three lines: the panel grows past its minimum.
        XCTAssertEqual(fitPrompt(usedHeight: 53.2, lineHeight: 17.6, maxLines: 6),
                       PromptFit(height: 54, scrolls: false, panelHeight: 120))
        // Exactly at the cap: no scroller yet.
        XCTAssertEqual(fitPrompt(usedHeight: 108, lineHeight: 18, maxLines: 6),
                       PromptFit(height: 108, scrolls: false, panelHeight: 174))
        // Past the cap: capped and scrolling.
        XCTAssertEqual(fitPrompt(usedHeight: 300, lineHeight: 18, maxLines: 6),
                       PromptFit(height: 108, scrolls: true, panelHeight: 174))
    }

    func testGrownFrame() {
        let f = CGRect(x: 100, y: 500, width: 420, height: 84)
        XCTAssertEqual(grownFrame(f, height: 120, visible: screen), CGRect(x: 100, y: 464, width: 420, height: 120))
        XCTAssertEqual(grownFrame(f, height: 120, visible: nil), CGRect(x: 100, y: 464, width: 420, height: 120))
        let low = CGRect(x: 100, y: 20, width: 420, height: 84)
        XCTAssertEqual(grownFrame(low, height: 174, visible: screen), CGRect(x: 100, y: 8, width: 420, height: 174),
                       "stops at the bottom of the screen")
        XCTAssertEqual(grownFrame(low, height: 174, visible: nil), CGRect(x: 100, y: -70, width: 420, height: 174))
    }

    func testStatusLayout() {
        XCTAssertEqual(statusLayout(containerWidth: 420, titleWidth: 40.2, hintMinX: 84),
                       StatusLayout(pickerFrame: CGRect(x: 347, y: 8, width: 67, height: 22), hintWidth: 253))
        // A long title is capped at 200.
        XCTAssertEqual(statusLayout(containerWidth: 420, titleWidth: 500, hintMinX: 84).pickerFrame.width, 200)
        // A tiny container leaves the hint no room, not negative room.
        XCTAssertEqual(statusLayout(containerWidth: 100, titleWidth: 100, hintMinX: 84).hintWidth, 0)
    }

    func testFade() {
        let view = CGRect(x: 0, y: 0, width: 300, height: 108)
        XCTAssertEqual(fade(visible: view, documentHeight: 50, scrolls: false),
                       Fade(top: false, bottom: false, edge: 24.0 / 108))
        XCTAssertEqual(fade(visible: view, documentHeight: 300, scrolls: true),
                       Fade(top: false, bottom: true, edge: 24.0 / 108), "at the top")
        XCTAssertEqual(fade(visible: view.offsetBy(dx: 0, dy: 100), documentHeight: 300, scrolls: true),
                       Fade(top: true, bottom: true, edge: 24.0 / 108), "in the middle")
        XCTAssertEqual(fade(visible: view.offsetBy(dx: 0, dy: 192), documentHeight: 300, scrolls: true),
                       Fade(top: true, bottom: false, edge: 24.0 / 108), "at the bottom")
        XCTAssertEqual(fade(visible: .zero, documentHeight: 0, scrolls: false).edge, 0.5, "zero height")
    }

    func testPopupHeight() {
        let item = PopupRow.item(PopupItem(target: .thread(id: "1"), title: "t", detail: "", toolTip: ""))
        XCTAssertEqual(popupHeight([.header("a"), item, item, .header("b"), item]), 34 + (2 * 22 + 3 * 24) + 8)
        XCTAssertEqual(popupHeight([.header("a"), item, item, .header("b"), item]), 158)
        XCTAssertEqual(popupHeight([]), 42)
        XCTAssertEqual(popupHeight(Array(repeating: item, count: 20)), 34 + 420 + 8, "the list caps and scrolls")
        XCTAssertLessThanOrEqual(2 * PopupMetrics.headerHeight + 15 * PopupMetrics.rowHeight, PopupMetrics.maxListHeight)
        XCTAssertEqual(PopupMetrics.padding, 8)
        XCTAssertEqual(PopupMetrics.gap, 4)
    }

    func testPopupFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(popupFrame(panel: CGRect(x: 100, y: 500, width: 420, height: 84), height: 200, visible: visible),
                       CGRect(x: 100, y: 296, width: 420, height: 200), "under the panel")
        XCTAssertEqual(popupFrame(panel: CGRect(x: 100, y: 150, width: 420, height: 84), height: 200, visible: visible),
                       CGRect(x: 100, y: 238, width: 420, height: 200), "above it near the bottom of the screen")
        // Room neither under nor above: kept on the screen.
        XCTAssertEqual(popupFrame(panel: CGRect(x: 1300, y: 100, width: 420, height: 84), height: 200,
                                  visible: CGRect(x: 0, y: 0, width: 1440, height: 300)),
                       CGRect(x: 1012, y: 92, width: 420, height: 200))
    }

    func testTargetLayout() {
        XCTAssertEqual(targetLayout(containerWidth: 420, labelWidth: 60.2, hintMinX: 104, hintWidth: 110),
                       TargetLayout(chipFrame: CGRect(x: 331, y: 9, width: 77, height: 20), hintWidth: 219))
        let wide = targetLayout(containerWidth: 420, labelWidth: 500, hintMinX: 104, hintWidth: 110)
        XCTAssertEqual(wide.chipFrame.width, 186)
        XCTAssertEqual(wide.hintWidth, 110, "the hint keeps its full width")
        let error = targetLayout(containerWidth: 420, labelWidth: 500, hintMinX: 104, hintWidth: 600)
        XCTAssertEqual(error.chipFrame.width, 60, "a long error shrinks the chip to its minimum")
        XCTAssertEqual(error.hintWidth, 236)
        let tiny = targetLayout(containerWidth: 100, labelWidth: 60.2, hintMinX: 104, hintWidth: 110)
        XCTAssertEqual(tiny.chipFrame.width, 60)
        XCTAssertEqual(tiny.hintWidth, 0, "never negative")
        XCTAssertEqual(TargetChipMetrics.height, 20)
        XCTAssertEqual(TargetChipMetrics.padding, 16)
        XCTAssertEqual(TargetChipMetrics.minWidth, 60)
        XCTAssertEqual(TargetChipMetrics.gap, 8)
    }
}
