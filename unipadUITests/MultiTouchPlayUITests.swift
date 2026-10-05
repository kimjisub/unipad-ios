import XCTest

/// Install Fixtures/PlaybackStop in Documents/UniPack before running; missing content fails the
/// check. Pad input XCUITest's public gestures can aim at pads, through the real touch path: one
/// finger dragged across pads (D) and the app leaving and returning (G). After each gesture every
/// pad must look as it did before it: a pressed pad is lit red, so a pad left lit by lost input
/// shows in the comparison. Several fingers at once (A, B, C, E, F), cancelled held touches (G) and
/// a finger resting beside the pads (I) are covered by MultiTouchPlayTests through the same pad
/// view: the public several-finger gestures (`tap(withNumberOfTaps:numberOfTouches:)`, `pinch`,
/// `rotate`) place fingers by the element's size, and the pad grid is occluded in the
/// accessibility tree by the larger theme image, so their fingers miss the pads.
/// Synthetic input, not physical fingers.
final class MultiTouchPlayUITests: XCTestCase {
    private let app = XCUIApplication()
    private var grid: XCUIElement { app.otherElements["playPadGrid"] }

    @MainActor
    func testDraggingAndLeavingTheAppLeaveNoPadLit() throws {
        continueAfterFailure = true
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launch()
        UITestSupport.dismissSystemAlerts()
        openPack()
        // Trace Log draws the tap path over the pads; it is left on by other checks.
        let menu = app.buttons["line.3.horizontal"]
        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "option panel never opened")
        UITestSupport.setPlayOption("Trace Log", on: false, in: app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "option panel never closed")
        let idle = try settledPads()
        UITestSupport.attachScreenshot("01-idle", to: self)

        pad(3, 3).press(forDuration: 0.3, thenDragTo: pad(3, 4))
        try expectNoPadLit(comparedWith: idle, after: "D drag to the next pad")
        pad(0, 0).press(forDuration: 0.2, thenDragTo: pad(7, 7))
        try expectNoPadLit(comparedWith: idle, after: "D drag across the grid")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "the play screen did not come back")
        try expectNoPadLit(comparedWith: idle, after: "G leaving and returning to the app")
        UITestSupport.attachScreenshot("02-after-gestures", to: self)

        menu.tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5), "the screen stopped answering")
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10), "exit left the screen unresponsive")
    }

    @MainActor
    private func openPack() {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Playback Stop Fixture")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "install Fixtures/PlaybackStop first")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        XCTAssertTrue(grid.waitForExistence(timeout: 15))
    }

    @MainActor
    private func pad(_ row: Int, _ col: Int) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(col) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8))
    }

    /// The pads' pixels once two consecutive shots agree, so a fading press is not compared.
    @MainActor
    private func settledPads() throws -> PadPixels {
        var last = try PadPixels(grid.screenshot())
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let next = try PadPixels(grid.screenshot())
            if next.changedPads(comparedWith: last).isEmpty { return next }
            last = next
        }
        return last
    }

    @MainActor
    private func expectNoPadLit(comparedWith idle: PadPixels, after gesture: String) throws {
        let now = try settledPads()
        let changed = now.changedPads(comparedWith: idle)
        if !changed.isEmpty {
            UITestSupport.attachScreenshot("lit-after-\(gesture)", to: self)
        }
        XCTAssertEqual(changed, [], "pads (row, column from 1) still differ from idle after \(gesture)")
    }
}

/// An 8x8 pad grid screenshot reduced to each pad's mean colour.
private struct PadPixels {
    struct Unreadable: Error {}
    let means: [[Double]]

    init(_ screenshot: XCUIScreenshot) throws {
        // A landscape screenshot is stored sideways with an orientation flag; draw it upright.
        let shot = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: shot.size, format: format).image { _ in shot.draw(at: .zero) }
        guard let image = upright.cgImage else { throw Unreadable() }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Unreadable() }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        means = (0..<64).map { index in
            let row = index / 8, col = index % 8
            // The middle half of each pad, clear of the borders shared with its neighbours.
            let xs = (col * width / 8 + width / 32)..<((col + 1) * width / 8 - width / 32)
            let ys = (row * height / 8 + height / 32)..<((row + 1) * height / 8 - height / 32)
            var sum = [0.0, 0.0, 0.0]
            for y in ys {
                for x in xs {
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 { sum[channel] += Double(bytes[offset + channel]) }
                }
            }
            let count = Double(xs.count * ys.count)
            return sum.map { $0 / count }
        }
    }

    /// Pads whose mean colour moved by more than a slight rendering difference, as "row,column" from 1.
    func changedPads(comparedWith other: PadPixels) -> [String] {
        means.indices.compactMap { index in
            let distance = zip(means[index], other.means[index]).map { abs($0 - $1) }.max() ?? 0
            return distance > 12 ? "\(index / 8 + 1),\(index % 8 + 1)" : nil
        }
    }
}
