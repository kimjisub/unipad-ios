#if os(iOS)
import SwiftUI
import Testing
@testable import unipad

/// Near a screen edge the system holds a touch back until it has ruled out a system swipe, which
/// would make the pads beside that edge late. The delay needs a real touch to show, so this checks
/// the request the system reads.
@MainActor
struct PlaySystemGestureTests {
    @Test func playScreenTakesTheFirstTouchAtEveryEdge() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let screen = UIHostingController(rootView: PlayView(packPath: "/no-such-pack").environment(AppRouter()))
        window.rootViewController = screen
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<50 where screen.preferredScreenEdgesDeferringSystemGestures != .all {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(screen.preferredScreenEdgesDeferringSystemGestures == .all)
    }
}
#endif
