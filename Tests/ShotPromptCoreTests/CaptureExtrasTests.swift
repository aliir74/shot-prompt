import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotPromptCore

final class CaptureExtrasTests: XCTestCase {
    func testCaptureRegion() {
        let px = CGSize(width: 400, height: 200)
        // A drag up-left or down-right gives the same rectangle.
        let r = CGRect(x: 100, y: 300, width: 200, height: 100)
        XCTAssertEqual(captureRegion(down: CGPoint(x: 100, y: 400), up: CGPoint(x: 300, y: 300), upAge: 1,
                                     imagePixels: px, scale: 2), r)
        XCTAssertEqual(captureRegion(down: CGPoint(x: 300, y: 300), up: CGPoint(x: 100, y: 400), upAge: 1,
                                     imagePixels: px, scale: 2), r)
        // A few pixels off is the same capture.
        XCTAssertEqual(captureRegion(down: CGPoint(x: 100, y: 400), up: CGPoint(x: 302.5, y: 301), upAge: 1,
                                     imagePixels: px, scale: 2)?.width, 202.5)
        // A click (window capture), a size that does not match, an old drag, no drag.
        XCTAssertNil(captureRegion(down: CGPoint(x: 5, y: 5), up: CGPoint(x: 5, y: 5), upAge: 1, imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: .zero, up: CGPoint(x: 300, y: 100), upAge: 1, imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: CGPoint(x: 100, y: 400), up: CGPoint(x: 300, y: 300), upAge: 20,
                                   imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: CGPoint(x: 100, y: 400), up: CGPoint(x: 300, y: 300), upAge: -1,
                                   imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: nil, up: .zero, upAge: 1, imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: .zero, up: nil, upAge: 1, imagePixels: px, scale: 2))
        XCTAssertNil(captureRegion(down: .zero, up: CGPoint(x: 1, y: 1), upAge: 1, imagePixels: px, scale: 0))
    }

    func testCoordinates() {
        XCTAssertEqual(topLeft(CGRect(x: 10, y: 700, width: 100, height: 50), primaryHeight: 1000),
                       CGRect(x: 10, y: 250, width: 100, height: 50))
        XCTAssertEqual(center(CGRect(x: 0, y: 0, width: 10, height: 20)), CGPoint(x: 5, y: 10))
    }

    func testDescribeElement() {
        XCTAssertNil(describeElement([]))
        XCTAssertNil(describeElement([ElementInfo()]))
        let button = ElementInfo(role: "AXButton", title: "Merge", domID: "merge", classes: ["btn", "primary", "x", "y"])
        XCTAssertEqual(describeElement([button]), "Button \u{201C}Merge\u{201D} #merge .btn.primary.x")
        // The nearest named ancestor, past unnamed ones, not the window or the page.
        let group = ElementInfo(role: "AXGroup", label: "Checks")
        XCTAssertEqual(describeElement([button, ElementInfo(role: "AXGroup"), group]),
                       "Button \u{201C}Merge\u{201D} #merge .btn.primary.x in Group \u{201C}Checks\u{201D}")
        XCTAssertEqual(describeElement([button, ElementInfo(role: "AXWebArea", title: "GitHub"),
                                        ElementInfo(role: "AXWindow", title: "w")]),
                       "Button \u{201C}Merge\u{201D} #merge .btn.primary.x")
        // Static text names itself; a text field's value (what you typed) never shows.
        XCTAssertEqual(describeElement([ElementInfo(role: "AXStaticText", value: "Build failed")]),
                       "StaticText \u{201C}Build failed\u{201D}")
        XCTAssertEqual(describeElement([ElementInfo(role: "AXTextField", value: "hunter2")]), "TextField")
        XCTAssertEqual(describeElement([ElementInfo(role: "custom")]), "custom")
    }

    func testOutlineRectAndWindowShotAdds() {
        let window = CGRect(x: 100, y: 50, width: 500, height: 400)
        XCTAssertEqual(outlineRect(region: CGRect(x: 200, y: 100, width: 50, height: 20), window: window,
                                   shotPixels: CGSize(width: 1000, height: 800)),
                       CGRect(x: 200, y: 100, width: 100, height: 40))
        XCTAssertNil(outlineRect(region: CGRect(x: 0, y: 0, width: 50, height: 20), window: window,
                                 shotPixels: CGSize(width: 1000, height: 800)))
        XCTAssertNil(outlineRect(region: .zero, window: .zero, shotPixels: .zero))
        XCTAssertTrue(windowShotAdds(capturePixels: CGSize(width: 100, height: 100), shotPixels: CGSize(width: 1000, height: 800)))
        XCTAssertFalse(windowShotAdds(capturePixels: CGSize(width: 996, height: 804), shotPixels: CGSize(width: 1000, height: 800)))
    }

    func writePNG(_ url: URL, width: Int, height: Int) {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    // The red channel minus the green one at a pixel (top-left origin): high on the outline.
    func redness(_ url: URL, _ x: Int, _ y: Int) -> Int {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Int(px[0]) - Int(px[1])
    }

    func testDrawOutlineAndPixelSize() throws {
        let dir = try makeTempDir(self)
        let url = dir.appendingPathComponent("w.png")
        writePNG(url, width: 300, height: 200)
        XCTAssertEqual(pixelSize(of: url), CGSize(width: 300, height: 200))
        XCTAssertTrue(drawOutline(on: url, rect: CGRect(x: 50, y: 40, width: 100, height: 60)))
        XCTAssertEqual(pixelSize(of: url), CGSize(width: 300, height: 200))
        XCTAssertGreaterThan(redness(url, 48, 70), 100, "left edge, just outside the capture")
        XCTAssertGreaterThan(redness(url, 100, 38), 100, "top edge, measured from the top")
        XCTAssertLessThan(redness(url, 100, 70), 10, "inside stays white")
        XCTAssertLessThan(redness(url, 50, 70), 10, "the capture's own edge is not covered")
        XCTAssertLessThan(redness(url, 250, 150), 10, "outside stays white")

        let text = dir.appendingPathComponent("x.txt")
        try "no".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertNil(pixelSize(of: text))
        XCTAssertFalse(drawOutline(on: text, rect: .zero))
    }

    func testPickWindow() {
        let windows = [
            ListedWindow(id: 1, pid: 9, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            ListedWindow(id: 2, pid: 5, layer: 25, bounds: CGRect(x: 0, y: 0, width: 900, height: 900)),
            ListedWindow(id: 3, pid: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
            ListedWindow(id: 4, pid: 5, layer: 0, bounds: CGRect(x: 400, y: 0, width: 300, height: 300)),
        ]
        // The app's frontmost normal window, or the one under the capture.
        XCTAssertEqual(pickWindow(windows, pid: 5, at: nil)?.id, 3)
        XCTAssertEqual(pickWindow(windows, pid: 5, at: CGPoint(x: 500, y: 100))?.id, 4)
        XCTAssertEqual(pickWindow(windows, pid: 5, at: CGPoint(x: 2000, y: 100))?.id, 3)
        XCTAssertNil(pickWindow(windows, pid: 7, at: nil))
    }

    func testImageGuide() {
        XCTAssertNil(imageGuide(captures: 1, windowShot: false))
        XCTAssertEqual(imageGuide(captures: 1, windowShot: true),
                       "Images: 1 is your capture; 2 is the whole window it was taken in, the capture outlined in red.")
        XCTAssertEqual(imageGuide(captures: 2, windowShot: false), "Images: 1 is your capture; 2 is another capture.")
        XCTAssertEqual(imageGuide(captures: 4, windowShot: false),
                       "Images: 1 is your capture; 2 to 4 are more captures, in the order taken.")
    }
}
