import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    var speed: Double = 30
    var fontSize: CGFloat = 14

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animating = false

    private var needsScroll: Bool { textWidth > containerWidth }
    private var scrollDistance: CGFloat { textWidth - containerWidth }
    private let pauseDuration: Double = 1.5

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .offset(x: offset)
                .onAppear {
                    containerWidth = geo.size.width
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    containerWidth = newWidth
                    resetAnimation()
                }
        }
        .frame(height: textHeight)
        .clipped()
        .overlay {
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(GeometryReader { geo in
                    Color.clear.onAppear {
                        textWidth = geo.size.width
                    }
                    .onChange(of: text) {
                        textWidth = geo.size.width
                        resetAnimation()
                    }
                })
                .frame(width: 0, height: 0)
                .hidden()
        }
        .onChange(of: textWidth) { _, _ in startAnimationIfNeeded() }
        .onChange(of: containerWidth) { _, _ in startAnimationIfNeeded() }
    }

    private var textHeight: CGFloat {
        #if canImport(UIKit)
        let uiFont = UIFont.systemFont(ofSize: fontSize)
        #else
        let uiFont = NSFont.systemFont(ofSize: fontSize)
        #endif
        return uiFont.lineHeight + 4
    }

    private func resetAnimation() {
        animating = false
        offset = 0
    }

    private func startAnimationIfNeeded() {
        guard needsScroll, !animating else { return }
        animating = true
        runScrollCycle()
    }

    private func runScrollCycle() {
        guard animating, needsScroll else {
            offset = 0
            animating = false
            return
        }

        let duration = scrollDistance / speed

        Task {
            try? await Task.sleep(for: .seconds(pauseDuration))
            guard animating else { return }
            withAnimation(.linear(duration: duration)) {
                offset = -scrollDistance
            }
            try? await Task.sleep(for: .seconds(duration + pauseDuration))
            guard animating else { return }
            withAnimation(.linear(duration: duration)) {
                offset = 0
            }
            try? await Task.sleep(for: .seconds(duration))
            guard animating else { return }
            runScrollCycle()
        }
    }
}
