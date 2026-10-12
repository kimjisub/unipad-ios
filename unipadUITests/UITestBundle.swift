//
//  UITestBundle.swift
//  unipadUITests
//

import XCTest

/// The UI test bundle's principal class (`NSPrincipalClass`), created once before any test runs.
///
/// UniPad runs only in landscape, but an iPad simulator boots standing upright. Held upright,
/// the app is drawn sideways while XCUITest still reports its frames unrotated, so a tap aimed
/// at an element lands somewhere else: Settings' back button reads as the screen's top-left
/// corner, where nothing is. Every test therefore starts with the device in landscape. A test
/// that turns the device to the other landscape side keeps it that way for the next test, as
/// it always has.
final class UITestBundle: NSObject, XCTestObservation {

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        MainActor.assumeIsolated {
            let device = XCUIDevice.shared
            if !device.orientation.isLandscape {
                device.orientation = .landscapeLeft
            }
        }
    }
}
