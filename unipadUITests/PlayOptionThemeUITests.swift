import XCTest

final class PlayOptionThemeUITests: XCTestCase {
    @MainActor
    private func checkPanel(colors: String?, expected: (Int, Int, Int), name: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let token = UUID().uuidString
        app.launchArguments += UITestSupport.englishLaunchArguments(token: token, isolated: true)
        app.launchArguments += ["-SelectedTheme", colors == nil ? "default" : "../ReleaseTests/\(token)/Theme"]
        if let colors {
            // Argument-domain defaults may parse JSON as a dictionary instead of a string.
            app.launchArguments += ["-UniPadReleaseThemeColors", Data(colors.utf8).base64EncodedString()]
        }
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        UITestSupport.openPlaybackStopFixture(in: app)
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        UITestSupport.setPlayOption("Feedback light", on: true, in: app)
        UITestSupport.attachScreenshot("\(name)-option-panel", to: self)
        let toggle = app.switches["Feedback light"].firstMatch
        XCTAssertTrue(toggle.exists)
        try assertTint(toggle, expected: expected)
        try assertTint(app.buttons["autoMapping"], expected: expected)
        app.buttons["Guide"].tap()
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        UITestSupport.attachScreenshot("\(name)-selected-mode", to: self)
        let modeColor = colors == nil || colors == "{}" ? (79, 195, 247) : expected
        try assertTint(app.buttons["Guide"], expected: modeColor)
    }

    @MainActor
    private func assertTint(_ element: XCUIElement, expected: (Int, Int, Int)) throws {
        let image = try XCTUnwrap(element.screenshot().image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let matching = stride(from: 0, to: pixels.count, by: 4).filter {
            abs(Int(pixels[$0]) - expected.0) < 12 &&
            abs(Int(pixels[$0 + 1]) - expected.1) < 12 &&
            abs(Int(pixels[$0 + 2]) - expected.2) < 12
        }.count
        XCTAssertGreaterThan(matching, 100, "the control must visibly use the expected accent: \(element)")
    }

    @MainActor func testDefaultThemeKeepsOrange() throws {
        try checkPanel(colors: nil, expected: (232, 164, 74), name: "default")
    }

    @MainActor func testThemeWithoutOptionAccentKeepsOrange() throws {
        try checkPanel(colors: "{}", expected: (232, 164, 74), name: "unspecified")
    }

    @MainActor func testExplicitOptionAccentColorsEnabledSwitch() throws {
        try checkPanel(colors: ##"{"option_window_checkbox":"#00B8D4"}"##,
                       expected: (0, 184, 212), name: "custom")
    }
}
