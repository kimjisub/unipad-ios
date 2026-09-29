import SwiftUI
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

    /// iPhone 16e landscape keeps 21pt at the bottom for the home indicator: the grid stays on the
    /// screen's centre line but in the middle of the safe area's height, so neither it nor its
    /// chain rows reach below the safe area (unipad-ios#37).
    @Test func padsKeepClearOfTheHomeIndicatorWhenTheSafeAreaIsLopsided() {
        let insets = EdgeInsets(top: 0, leading: 47, bottom: 21, trailing: 47)
        for bottomRow in [false, true] {
            let l = PlayLayout(viewSize: CGSize(width: 750, height: 369), buttonX: 8, buttonY: 8, showAllSides: bottomRow, reservedWidth: menuStrip, safeAreaInsets: insets)
            let chainRowHeight = bottomRow ? l.chainHeight : 0
            #expect(l.padCenterX + insets.leading == CGFloat(844) / 2)
            #expect(l.padCenterY - l.gridHeight / 2 - chainRowHeight >= -0.001)
            #expect(l.padCenterY + l.gridHeight / 2 + chainRowHeight <= 369.001)
            #expect(l.cellSize == CGFloat(369) / CGFloat(bottomRow ? 10 : 8))
            assertChainColumnsFit(l, width: 750)
        }
    }

    /// On iPhone 16e the pads' centre is 10.5pt above the screen's, so a 7:2 theme image grows from
    /// the screen's height to 411pt to reach the bottom edge from there.
    @Test func themeImageCoversTheScreenFromThePadsCentre() {
        let size = PlayLayout.coverSize(of: CGSize(width: 2520, height: 720), centredOn: CGPoint(x: 422, y: 184.5), in: CGSize(width: 844, height: 390))
        #expect(abs(size.height - 411) < 0.001)
        #expect(abs(size.width - 411 * 3.5) < 0.001)
        let centred = PlayLayout.coverSize(of: CGSize(width: 2520, height: 720), centredOn: CGPoint(x: 422, y: 195), in: CGSize(width: 844, height: 390))
        #expect(abs(centred.height - 390) < 0.001)
    }

    @Test func largeGridsStayInsideTheScreen() {
        let l = layout(750, 381, bottomRow: true, buttons: 16)
        assertChainColumnsFit(l, width: 750)
    }
}
