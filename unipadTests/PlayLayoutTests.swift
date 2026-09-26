import CoreGraphics
import Testing
@testable import unipad

struct PlayLayoutTests {
    private let menuStrip: CGFloat = 56

    private func layout(_ width: CGFloat, _ height: CGFloat, bottomRow: Bool = false, buttons: Int = 8) -> PlayLayout {
        PlayLayout(viewSize: CGSize(width: width, height: height), buttonX: buttons, buttonY: buttons, showAllSides: bottomRow, reservedWidth: menuStrip)
    }

    private func assertChainColumnsFit(_ l: PlayLayout, width: CGFloat) {
        let leftChainEdge = l.padCenterX - l.gridWidth / 2 - l.chainWidth
        let rightChainEdge = l.padCenterX + l.gridWidth / 2 + l.chainWidth
        #expect(leftChainEdge >= -0.001)
        #expect(rightChainEdge <= width - menuStrip + 0.001)
    }

    @Test(arguments: [
        (CGFloat(750), CGFloat(381)),   // iPhone 17 Pro landscape safe area
        (CGFloat(667), CGFloat(375)),   // iPhone SE landscape
        (CGFloat(1133), CGFloat(744)),  // iPad mini landscape
        (CGFloat(1194), CGFloat(814)),  // iPad Pro 11" landscape
    ])
    func landscapePadsSitOnTheScreenCentre(width: CGFloat, height: CGFloat) {
        for bottomRow in [false, true] {
            let l = layout(width, height, bottomRow: bottomRow)
            #expect(l.padCenterX == width / 2)
            assertChainColumnsFit(l, width: width)
        }
    }

    @Test func padSizeIsUnchangedByCentring() {
        let l = layout(750, 381)
        #expect(l.cellSize == CGFloat(381) / 8)
    }

    @Test(arguments: [
        (CGFloat(390), CGFloat(800)),  // portrait-shaped phone window
        (CGFloat(507), CGFloat(1012)), // iPad split view, narrow side
        (CGFloat(1376), CGFloat(1012)), // iPad Pro 13" landscape: 0.5pt short of room
    ])
    func tightWindowsShiftOnlyEnoughToClearTheMenuStrip(width: CGFloat, height: CGFloat) {
        let l = layout(width, height)
        #expect(l.padCenterX < width / 2)
        #expect(abs(l.padCenterX + l.gridWidth / 2 + l.chainWidth - (width - menuStrip)) < 0.001)
        assertChainColumnsFit(l, width: width)
    }

    @Test func largeGridsStayInsideTheScreen() {
        let l = layout(750, 381, bottomRow: true, buttons: 16)
        assertChainColumnsFit(l, width: 750)
    }
}
