import CoreGraphics
import Testing
@testable import unipad

/// The numbers are the ones an upright iPad reports on iPadOS 27: a 32pt status bar over a
/// 10pt top safe area.
struct StatusBarOverlapTests {
    private func overlap(windowOffset: CGFloat, statusBarBottom: CGFloat = 32, safeAreaTop: CGFloat = 10) -> CGFloat {
        StatusBarOverlap.amount(statusBarBottom: statusBarBottom, safeAreaTop: safeAreaTop, windowOffset: windowOffset)
    }

    @Test(arguments: [0, 0.5, -0.5, 1.0 / 3, -0.25])
    func fullHeightWindowClearsTheStatusBar(windowOffset: CGFloat) {
        #expect(overlap(windowOffset: windowOffset) == 22)
    }

    /// Offsets measured on iPadOS 27 for upright windows 625pt and 375pt high and a landscape
    /// window 486pt high.
    @Test(arguments: [-104.5, -230, -231.5, -1, 1])
    func shorterWindowKeepsItsSafeArea(windowOffset: CGFloat) {
        #expect(overlap(windowOffset: windowOffset) == 0)
    }

    @Test func safeAreaThatAlreadyClearsTheBarAddsNothing() {
        #expect(overlap(windowOffset: 0, statusBarBottom: 24, safeAreaTop: 24) == 0)
        #expect(overlap(windowOffset: 0, statusBarBottom: 0, safeAreaTop: 20) == 0)
    }
}
