import SwiftUI
import QuartzCore

struct PadGridView: View {
    let columns: Int
    let rows: Int
    let isSquareButton: Bool
    let padColors: [[Color]]
    let padLedColors: [[Color]]
    let padItems: [[ChannelManager.Item?]]
    var btnImage: PlatformImage? = nil
    var btnPressedImage: PlatformImage? = nil
    var phantomImage: PlatformImage? = nil
    var phantomVariantImage: PlatformImage? = nil
    var renderVersion: Int = 0
    var padGuideTargets: [[Int64]] = []
    var traceLogSequence: [(x: Int, y: Int)]? = nil
    var traceLogColor: Color = .white
    var onPadTouch: (Int, Int, Bool) -> Void

    private var hasActiveGuide: Bool {
        padGuideTargets.contains { row in row.contains { $0 > 0 } }
    }

    var body: some View {
        GeometryReader { geometry in
            let squareSize = min(
                geometry.size.width / CGFloat(columns),
                geometry.size.height / CGFloat(rows)
            )
            let cellWidth = isSquareButton ? squareSize : geometry.size.width / CGFloat(columns)
            let cellHeight = isSquareButton ? squareSize : geometry.size.height / CGFloat(rows)
            let gridWidth = cellWidth * CGFloat(columns)
            let gridHeight = cellHeight * CGFloat(rows)
            let offsetX = (geometry.size.width - gridWidth) / 2
            let offsetY = (geometry.size.height - gridHeight) / 2

            ZStack {
                TimelineView(.animation(minimumInterval: hasActiveGuide ? nil : 1.0)) { timeline in
                let _ = timeline.date // force redraw on timeline tick
                Canvas { context, size in
                    let nowMs = Int64(CACurrentMediaTime() * 1000)

                    let resolvedBtnImage = btnImage.flatMap {
                        context.resolve(Image(platformImage: $0))
                    }
                    let resolvedBtnPressedImage = btnPressedImage.flatMap {
                        context.resolve(Image(platformImage: $0))
                    }
                    let resolvedPhantomImage = phantomImage.flatMap {
                        context.resolve(Image(platformImage: $0))
                    }
                    let resolvedPhantomVariantImage = phantomVariantImage.flatMap {
                        context.resolve(Image(platformImage: $0))
                    }

                    let phantomEnabled = rows < 16 && columns < 16
                    let centerX = rows / 2 - 1
                    let centerY = columns / 2 - 1
                    let shouldUseVariant = phantomEnabled &&
                        isSquareButton &&
                        rows % 2 == 0 &&
                        columns % 2 == 0 &&
                        resolvedPhantomVariantImage != nil

                    for x in 0..<rows {
                        for y in 0..<columns {
                            let x0 = offsetX + CGFloat(y) * cellWidth
                            let y0 = offsetY + CGFloat(x) * cellHeight
                            let x1 = offsetX + CGFloat(y + 1) * cellWidth
                            let y1 = offsetY + CGFloat(x + 1) * cellHeight
                            let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)

                            let ledColor = (x < padLedColors.count && y < padLedColors[x].count)
                                ? padLedColors[x][y]
                                : Color.clear
                            let item = (x < padItems.count && y < padItems[x].count)
                                ? padItems[x][y]
                                : nil

                            if item?.channel == .pressed {
                                if let pressedImg = resolvedBtnPressedImage {
                                    context.draw(pressedImg, in: rect)
                                } else if let btnImg = resolvedBtnImage {
                                    context.draw(btnImg, in: rect)
                                } else {
                                    context.fill(
                                        Path(roundedRect: rect, cornerRadius: 4),
                                        with: .color(Color(hex: 0x2A2A2A))
                                    )
                                }
                            } else if let btnImg = resolvedBtnImage {
                                context.draw(btnImg, in: rect)
                            } else {
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: 4),
                                    with: .color(Color(hex: 0x2A2A2A))
                                )
                            }

                            if ledColor != .clear {
                                context.fill(
                                    Path(roundedRect: rect, cornerRadius: 4),
                                    with: .color(ledColor)
                                )
                            }

                            // Guide countdown mask animation
                            let guideTarget = (x < padGuideTargets.count && y < padGuideTargets[x].count)
                                ? padGuideTargets[x][y]
                                : 0
                            if guideTarget > 0 {
                                let remaining = max(0, guideTarget - nowMs)
                                let duration = max(Int64(100), guideTarget - (nowMs - Int64(AutoPlayRunner.guideLookaheadMs)))
                                let progress = CGFloat(1.0 - Double(remaining) / Double(duration))
                                let clamped = min(max(progress, 0), 1)
                                let maxBorder = min(rect.width, rect.height) / 2
                                let revealed = maxBorder * clamped
                                let maskRect = CGRect(
                                    x: rect.minX + revealed,
                                    y: rect.minY + revealed,
                                    width: rect.width - revealed * 2,
                                    height: rect.height - revealed * 2
                                )
                                if maskRect.width > 0 && maskRect.height > 0 {
                                    context.fill(
                                        Path(roundedRect: maskRect, cornerRadius: 4),
                                        with: .color(Color.black.opacity(0.867))
                                    )
                                }
                            }

                            guard phantomEnabled else { continue }

                            let variantRotation: Angle?
                            if shouldUseVariant {
                                if x == centerX && y == centerY {
                                    variantRotation = .degrees(0)
                                } else if x == centerX + 1 && y == centerY {
                                    variantRotation = .degrees(270)
                                } else if x == centerX && y == centerY + 1 {
                                    variantRotation = .degrees(90)
                                } else if x == centerX + 1 && y == centerY + 1 {
                                    variantRotation = .degrees(180)
                                } else {
                                    variantRotation = nil
                                }
                            } else {
                                variantRotation = nil
                            }

                            if let rotation = variantRotation,
                               let variant = resolvedPhantomVariantImage {
                                let cx = rect.midX
                                let cy = rect.midY
                                var rotatedContext = context
                                rotatedContext.translateBy(x: cx, y: cy)
                                rotatedContext.rotate(by: rotation)
                                rotatedContext.translateBy(x: -cx, y: -cy)
                                rotatedContext.draw(variant, in: rect)
                            } else if let phantom = resolvedPhantomImage {
                                context.draw(phantom, in: rect)
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                } // TimelineView

                if let sequence = traceLogSequence, !sequence.isEmpty {
                    Canvas { context, size in
                        let cellMin = min(cellWidth, cellHeight)
                        let maxOffset = cellMin * 0.3
                        let strokeWidth = max(1.5, cellMin * 0.04)
                        let dotRadius = max(2.5, cellMin * 0.06)

                        var visitTotal: [Int: Int] = [:]
                        for point in sequence {
                            let key = point.x * columns + point.y
                            visitTotal[key, default: 0] += 1
                        }

                        var visitIndex: [Int: Int] = [:]
                        var points: [CGPoint] = []

                        for point in sequence {
                            let key = point.x * columns + point.y
                            let total = visitTotal[key, default: 1]
                            let idx = visitIndex[key, default: 0]
                            visitIndex[key] = idx + 1

                            var ox: CGFloat = 0
                            var oy: CGFloat = 0
                            if total > 1 {
                                let t = CGFloat(idx) / CGFloat(total - 1) - 0.5
                                ox = t * maxOffset
                                oy = t * maxOffset
                            }

                            let cx = offsetX + CGFloat(point.y) * cellWidth + cellWidth / 2 + ox
                            let cy = offsetY + CGFloat(point.x) * cellHeight + cellHeight / 2 + oy
                            points.append(CGPoint(x: cx, y: cy))
                        }

                        if points.count >= 2 {
                            var linePath = Path()
                            linePath.move(to: points[0])
                            for i in 1..<points.count {
                                linePath.addLine(to: points[i])
                            }
                            context.stroke(
                                linePath,
                                with: .color(traceLogColor.opacity(0.85)),
                                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                            )
                        }

                        for point in points {
                            let dotRect = CGRect(
                                x: point.x - dotRadius,
                                y: point.y - dotRadius,
                                width: dotRadius * 2,
                                height: dotRadius * 2
                            )
                            context.fill(
                                Path(ellipseIn: dotRect),
                                with: .color(traceLogColor.opacity(0.95))
                            )
                        }
                    }
                    .allowsHitTesting(false)
                }

                MultiTouchView(
                    gridOrigin: CGPoint(x: offsetX, y: offsetY),
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    rows: rows,
                    columns: columns,
                    onPadTouch: onPadTouch
                )
            }
        }
        .clipped()
    }
}

// MARK: - Multi-touch Handler

private struct MultiTouchModifier: ViewModifier {
    let gridOrigin: CGPoint
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let rows: Int
    let columns: Int
    let onPadTouch: (Int, Int, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                MultiTouchView(
                    gridOrigin: gridOrigin,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight,
                    rows: rows,
                    columns: columns,
                    onPadTouch: onPadTouch
                )
            }
    }
}

extension View {
    func multiTouchHandler(
        gridOrigin: CGPoint,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        rows: Int,
        columns: Int,
        onPadTouch: @escaping (Int, Int, Bool) -> Void
    ) -> some View {
        modifier(MultiTouchModifier(
            gridOrigin: gridOrigin,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            rows: rows,
            columns: columns,
            onPadTouch: onPadTouch
        ))
    }
}

#if canImport(UIKit)
import UIKit

struct MultiTouchView: UIViewRepresentable {
    let gridOrigin: CGPoint
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let rows: Int
    let columns: Int
    let onPadTouch: (Int, Int, Bool) -> Void

    func makeUIView(context: Context) -> MultiTouchUIView {
        let view = MultiTouchUIView()
        view.isMultipleTouchEnabled = true
        view.gridOrigin = gridOrigin
        view.cellWidth = cellWidth
        view.cellHeight = cellHeight
        view.rows = rows
        view.columns = columns
        view.onPadTouch = onPadTouch
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: MultiTouchUIView, context: Context) {
        uiView.gridOrigin = gridOrigin
        uiView.cellWidth = cellWidth
        uiView.cellHeight = cellHeight
        uiView.rows = rows
        uiView.columns = columns
        uiView.onPadTouch = onPadTouch
    }
}

class MultiTouchUIView: UIView {
    var gridOrigin: CGPoint = .zero
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var rows: Int = 0
    var columns: Int = 0
    var onPadTouch: ((Int, Int, Bool) -> Void)?

    private var activeTouches: [UITouch: (Int, Int)] = [:]

    private func padAt(_ point: CGPoint) -> (Int, Int)? {
        let col = Int((point.x - gridOrigin.x) / cellWidth)
        let row = Int((point.y - gridOrigin.y) / cellHeight)
        guard row >= 0, row < rows, col >= 0, col < columns else { return nil }
        return (row, col)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let (row, col) = padAt(point) else { continue }
            activeTouches[touch] = (row, col)
            onPadTouch?(row, col, true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            let next = padAt(point)
            let prev = activeTouches[touch]

            if let prev, next == nil {
                onPadTouch?(prev.0, prev.1, false)
                activeTouches.removeValue(forKey: touch)
                continue
            }

            guard let (row, col) = next else { continue }
            if let prev, prev != (row, col) {
                onPadTouch?(prev.0, prev.1, false)
                activeTouches[touch] = (row, col)
                onPadTouch?(row, col, true)
            } else if prev == nil {
                activeTouches[touch] = (row, col)
                onPadTouch?(row, col, true)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if let (row, col) = activeTouches.removeValue(forKey: touch) {
                onPadTouch?(row, col, false)
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

#elseif canImport(AppKit)
import AppKit

struct MultiTouchView: NSViewRepresentable {
    let gridOrigin: CGPoint
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let rows: Int
    let columns: Int
    let onPadTouch: (Int, Int, Bool) -> Void

    func makeNSView(context: Context) -> MultiTouchNSView {
        let view = MultiTouchNSView()
        view.gridOrigin = gridOrigin
        view.cellWidth = cellWidth
        view.cellHeight = cellHeight
        view.rows = rows
        view.columns = columns
        view.onPadTouch = onPadTouch
        return view
    }

    func updateNSView(_ nsView: MultiTouchNSView, context: Context) {
        nsView.gridOrigin = gridOrigin
        nsView.cellWidth = cellWidth
        nsView.cellHeight = cellHeight
        nsView.rows = rows
        nsView.columns = columns
        nsView.onPadTouch = onPadTouch
    }
}

class MultiTouchNSView: NSView {
    var gridOrigin: CGPoint = .zero
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var rows: Int = 0
    var columns: Int = 0
    var onPadTouch: ((Int, Int, Bool) -> Void)?

    private var activeCell: (Int, Int)?

    private func padAt(_ point: CGPoint) -> (Int, Int)? {
        let flippedY = bounds.height - point.y
        let col = Int((point.x - gridOrigin.x) / cellWidth)
        let row = Int((flippedY - gridOrigin.y) / cellHeight)
        guard row >= 0, row < rows, col >= 0, col < columns else { return nil }
        return (row, col)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (row, col) = padAt(point) else { return }
        activeCell = (row, col)
        onPadTouch?(row, col, true)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = padAt(point)

        if activeCell != nil, next == nil {
            if let (row, col) = activeCell {
                onPadTouch?(row, col, false)
            }
            activeCell = nil
            return
        }

        guard let (row, col) = next else { return }
        if let prev = activeCell, prev != (row, col) {
            onPadTouch?(prev.0, prev.1, false)
            activeCell = (row, col)
            onPadTouch?(row, col, true)
        } else if activeCell == nil {
            activeCell = (row, col)
            onPadTouch?(row, col, true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let (row, col) = activeCell {
            onPadTouch?(row, col, false)
            activeCell = nil
        }
    }
}
#endif
