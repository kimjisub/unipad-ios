import SwiftUI
import Testing
@testable import unipad

struct PlayLayoutTests {
    private let menuStrip: CGFloat = 56

    private func layout(_ width: CGFloat, _ height: CGFloat, bottomRow: Bool = false, buttons: Int = 8) -> PlayLayout {
        PlayLayout(viewSize: CGSize(width: width, height: height), buttonX: buttons, buttonY: buttons, showAllSides: bottomRow, reservedWidth: menuStrip)
    }

    private func padFrame(of l: PlayLayout) -> CGRect {
        CGRect(x: l.padCenterX - l.gridWidth / 2, y: l.padCenterY - l.gridHeight / 2, width: l.gridWidth, height: l.gridHeight)
    }

    /// The chain strips as PlayView places them: a column on each side and, with `rows`, a row
    /// above and below, each eight chains long and centred on the pads.
    private func chainStrips(of l: PlayLayout, rows: Bool) -> [CGRect] {
        let pads = padFrame(of: l)
        let side = l.chainWidth * 8
        var strips = [
            CGRect(x: pads.minX - l.chainWidth, y: l.padCenterY - side / 2, width: l.chainWidth, height: side),
            CGRect(x: pads.maxX, y: l.padCenterY - side / 2, width: l.chainWidth, height: side),
        ]
        if rows {
            strips += [
                CGRect(x: l.padCenterX - side / 2, y: pads.minY - l.chainHeight, width: side, height: l.chainHeight),
                CGRect(x: l.padCenterX - side / 2, y: pads.maxY, width: side, height: l.chainHeight),
            ]
        }
        return strips
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

    @Test(arguments: [
        (CGFloat(750), CGFloat(382)), // iPhone 17 Pro safe area
        (CGFloat(667), CGFloat(375)),
        (CGFloat(1133), CGFloat(744)),
        (CGFloat(1194), CGFloat(814)),
        (CGFloat(390), CGFloat(800)),
        (CGFloat(507), CGFloat(1012)),
    ])
    func chainStripsFitWithoutCoveringPadsOrEachOther(width: CGFloat, height: CGFloat) {
        for rows in 1...8 {
            for columns in 1...8 {
                for chainRows in [false, true] {
                    let l = PlayLayout(viewSize: CGSize(width: width, height: height), buttonX: rows, buttonY: columns, showAllSides: chainRows, reservedWidth: menuStrip)
                    let pads = padFrame(of: l)
                    let strips = chainStrips(of: l, rows: chainRows)
                    let safe = CGRect(x: 0, y: 0, width: width - menuStrip, height: height).insetBy(dx: -0.001, dy: -0.001)
                    #expect(l.chainWidth > 0)
                    #expect(l.chainWidth <= l.cellSize)
                    for strip in strips {
                        #expect(safe.contains(strip))
                        #expect(strip.intersection(pads).width <= 0.001 || strip.intersection(pads).height <= 0.001)
                    }
                    for first in strips.indices {
                        for second in strips.indices where second > first {
                            let intersection = strips[first].intersection(strips[second])
                            #expect(intersection.isNull || intersection.width <= 0.001 || intersection.height <= 0.001)
                        }
                    }
                }
            }
        }
    }

    /// A tall 8x4 pack's top chain row is twice as wide as its pads, so it reaches past the right
    /// chain column, under the logo when the window is small, as a resized iPad window can be.
    @Test(arguments: [
        (CGFloat(750), CGFloat(382)), // iPhone 17 Pro safe area
        (CGFloat(667), CGFloat(375)),
        (CGFloat(568), CGFloat(320)),
        (CGFloat(1133), CGFloat(744)),
        (CGFloat(1210), CGFloat(809)),
        (CGFloat(520), CGFloat(320)), // a resized iPad window
        (CGFloat(600), CGFloat(400)),
    ])
    func logoStaysClearOfPadsChainsAndMenu(width: CGFloat, height: CGFloat) {
        for (rows, columns) in [(8, 4), (8, 8), (4, 3)] {
            for chainRows in [false, true] {
                let l = PlayLayout(viewSize: CGSize(width: width, height: height), buttonX: rows, buttonY: columns, showAllSides: chainRows, reservedWidth: menuStrip)
                let logo = l.logoFrame
                let shape = "\(rows)x\(columns) rows=\(chainRows) in \(width)x\(height): logo \(logo)"
                #expect(logo.maxX <= width - menuStrip + 0.001, "\(shape)")
                #expect(logo.width <= 90, "\(shape)")
                for obstacle in [padFrame(of: l)] + chainStrips(of: l, rows: chainRows) {
                    let overlap = logo.intersection(obstacle)
                    #expect(overlap.isNull || overlap.width <= 0.001 || overlap.height <= 0.001, "\(shape) covers \(obstacle)")
                }
            }
        }
    }

    /// An 8x8 pack's chain rows never reach past its chain columns, so its logo keeps the place
    /// beside the right chain column it always had.
    @Test(arguments: [(CGFloat(750), CGFloat(382)), (CGFloat(1133), CGFloat(744))])
    func eightByEightLogoKeepsItsPlace(width: CGFloat, height: CGFloat) {
        for chainRows in [false, true] {
            let l = PlayLayout(viewSize: CGSize(width: width, height: height), buttonX: 8, buttonY: 8, showAllSides: chainRows, reservedWidth: menuStrip)
            let padRight = l.padCenterX + l.gridWidth / 2 + l.chainWidth
            #expect(abs(l.logoFrame.width - min(90, width - padRight - menuStrip - 16)) < 0.001)
            #expect(abs(l.logoFrame.maxX - (width - menuStrip - 8)) < 0.001)
            #expect(l.logoFrame.minY == 8 && l.logoFrame.height == 40)
        }
    }

    @Test func smallPackKeepsPadSizeAndCentre() {
        for chainRows in [false, true] {
            let l = PlayLayout(viewSize: CGSize(width: 750, height: 382), buttonX: 4, buttonY: 3, showAllSides: chainRows, reservedWidth: menuStrip)
            #expect(l.cellSize == 382 / CGFloat(chainRows ? 6 : 4))
            #expect(l.padCenterX == 375)
            #expect(l.padCenterY == 191)
            #expect(l.chainWidth * 8 <= max(l.gridWidth, l.gridHeight) + 0.001)
            #expect(l.chainWidth * 8 <= 382.001)
        }
    }


    /// `squareButton=false` asks the pad view to stretch its cells to the grid, but PlayView sizes
    /// the grid from square cells, so the pads the screen draws and hits are the same either way.
    @MainActor
    @Test(arguments: [(4, 3), (8, 8)])
    func squareButtonFalseDrawsTheSameSquarePads(rows: Int, columns: Int) async throws {
        for size in [CGSize(width: 750, height: 381), CGSize(width: 1194, height: 814)] {
            let l = PlayLayout(viewSize: size, buttonX: rows, buttonY: columns, reservedWidth: menuStrip)
            let square = try padTouchGrid(rows: rows, columns: columns, square: true, in: l)
            let rect = try padTouchGrid(rows: rows, columns: columns, square: false, in: l)
            #expect(rect == square, "\(rows)x\(columns) in \(size)")
            #expect(square.cell == CGSize(width: l.cellSize, height: l.cellSize), "\(rows)x\(columns) in \(size)")
            #expect(square.origin == .zero, "\(rows)x\(columns) in \(size)")
        }
    }

    private struct PadTouchGrid: Equatable {
        let origin: CGPoint
        let cell: CGSize
    }

    /// The cells the pad view hits, as PlayView frames it.
    @MainActor
    private func padTouchGrid(rows: Int, columns: Int, square: Bool, in l: PlayLayout) throws -> PadTouchGrid {
        let grid = PadGridView(columns: columns, rows: rows, isSquareButton: square, padColors: [], padLedColors: [],
                               padItems: [], onPadTouch: { _, _, _, _ in })
            .frame(width: l.gridWidth, height: l.gridHeight)
        let window = try UIWindow.showing(grid, frame: CGRect(x: 0, y: 0, width: l.gridWidth, height: l.gridHeight))
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        func find(_ view: UIView) -> MultiTouchUIView? {
            (view as? MultiTouchUIView) ?? view.subviews.lazy.compactMap(find).first
        }
        let pads = try #require(find(window))
        return PadTouchGrid(origin: pads.gridOrigin, cell: CGSize(width: pads.cellWidth, height: pads.cellHeight))
    }
}
