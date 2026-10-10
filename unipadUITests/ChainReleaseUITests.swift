import CryptoKit
import XCTest

/// The release suite stages the unchanged ChainRelease delayed archive in an isolated library
/// and requires a pass. Elsewhere, install it in Documents/UniPack; a missing pack skips the check.
/// One actual simulator finger holds the first pad through the pack's 100 ms chain move.
/// Audio stop targets are independently checked by ChainReleaseTests, not inferred here.
final class ChainReleaseUITests: XCTestCase {
    @MainActor
    func testOneFingerThroughPackChainMoveAndRelease() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let archive = UITestSupport.isReleaseSuite ? try Self.approvedArchive() : nil
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "chain-release", archive: archive)
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chain Release v1 delayed")).firstMatch
        let installed = title.waitForExistence(timeout: 10)
        if archive != nil {
            XCTAssertTrue(installed, "the release suite must stage Chain Release v1 delayed")
        } else if !installed {
            throw XCTSkip("Chain Release v1 delayed is not installed in Documents/UniPack; chain release UI was not checked")
        }
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        UITestSupport.attachScreenshot("01-before-pad-press", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: 0.4)
        XCTAssertTrue(grid.exists)
        UITestSupport.attachScreenshot("02-after-pack-chain-move-and-release", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.1875)).tap()
        UITestSupport.attachScreenshot("03-after-second-pad-release", to: self)
        app.buttons["line.3.horizontal"].tap()
        XCTAssertTrue(app.buttons["rectangle.portrait.and.arrow.right"].waitForExistence(timeout: 5))
        app.buttons["rectangle.portrait.and.arrow.right"].tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
        UITestSupport.attachScreenshot("04-home-after-exit", to: self)
    }

    /// The simulator runner reads the reviewed copy from the source tree and refuses changed bytes.
    private static func approvedArchive() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("unipadTests/Fixtures/ChainRelease/delayed.uni")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "7f8647fc894b4226df180061d94febaa9306c0a2c1a3d019299b47a6c56c7236",
                       "delayed.uni must match the approved chain-release-v1 manifest")
        return data
    }
}
