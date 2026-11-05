import CoreGraphics
import Testing
@testable import unipad

struct WindowFitTests {
    private let iPad = CGSize(width: 1210, height: 834)

    private func fills(_ width: CGFloat, _ height: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> Bool {
        WindowFit.fillsDisplay(windowFrame: CGRect(x: x, y: y, width: width, height: height), displaySize: iPad)
    }

    @Test func aWindowTheSizeOfTheDisplayFillsIt() {
        #expect(fills(1210, 834))
        #expect(fills(834, 1210), "the other orientation, reached first during a rotation")
        #expect(fills(1210, 833.5), "half-point rounding, smaller")
        #expect(fills(1210.5, 834), "half-point rounding, larger")
    }

    @Test(arguments: [(572, 834), (1210, 800), (834, 486), (375, 500)] as [(CGFloat, CGFloat)])
    func aResizedWindowDoesNotFillTheDisplay(width: CGFloat, height: CGFloat) {
        #expect(!fills(width, height))
    }

    @Test func aWindowLargerThanTheDisplayIsOnAnotherOne() {
        #expect(!fills(1280, 1440), "half of a 2560x1440 external display")
        #expect(!fills(2560, 1440))
    }

    @Test func aWindowMovedOffTheDisplayCornerDoesNotFillIt() {
        #expect(!fills(1210, 834, x: 262))
        #expect(!fills(1210, 834, y: 135))
    }
}
