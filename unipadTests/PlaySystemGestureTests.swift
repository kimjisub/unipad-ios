#if os(iOS)
import SwiftUI
import Testing
@testable import unipad

/// Near a screen edge the system holds a touch back until it has ruled out a system swipe, which
/// would make the pads beside that edge late. The delay needs a real touch to show, so these check
/// what the system reads: it starts at the window's root and follows the child each controller names.
@MainActor
struct PlaySystemGestureTests {
    private let router = AppRouter()

    @Test func playScreenTakesTheFirstTouchAtEveryEdge() async throws {
        try await inStack { window in
            router.navigate(to: .play(packPath: "/no-such-pack"))
            try await expectEveryEdgeDeferred(in: window)
        }
    }

    @Test func packListKeepsSystemSwipesAfterThePlayScreenCloses() async throws {
        try await inStack { window in
            router.navigate(to: .play(packPath: "/no-such-pack"))
            try await expectEveryEdgeDeferred(in: window)
            router.pop()
            try await expectSystemSwipes(in: window)
        }
    }

    @Test func connectionScreenOverThePlayScreenKeepsSystemSwipes() async throws {
        try await inStack { window in
            router.navigate(to: .play(packPath: "/no-such-pack"))
            try await expectEveryEdgeDeferred(in: window)
            router.navigateToMidiSelectIfNeeded()
            try await expectSystemSwipes(in: window)
            router.pop()
            try await expectEveryEdgeDeferred(in: window)
        }
    }

    private func inStack(_ body: (UIWindow) async throws -> Void) async throws {
        let window = try UIWindow.showing(PlayStack(router: router))
        defer { window.isHidden = true }
        try await expectSystemSwipes(in: window)
        try await body(window)
        router.popToRoot()
        try await expectSystemSwipes(in: window)
    }

    private func expectEveryEdgeDeferred(in window: UIWindow) async throws {
        try await PlayUsageScenario.waitWhile { deferredEdges(in: window) != .all }
        #expect(deferredEdges(in: window) == .all)
    }

    /// The top and bottom edges are the ones only the play screen defers. A navigation stack
    /// already defers the left and right ones by itself.
    private func expectSystemSwipes(in window: UIWindow) async throws {
        let swipes: UIRectEdge = [.top, .bottom]
        try await PlayUsageScenario.waitWhile { !deferredEdges(in: window).isDisjoint(with: swipes) }
        #expect(deferredEdges(in: window).isDisjoint(with: swipes))
    }

    private func deferredEdges(in window: UIWindow) -> UIRectEdge {
        guard var controller = window.rootViewController else { return [] }
        while let child = controller.childForScreenEdgesDeferringSystemGestures { controller = child }
        return controller.preferredScreenEdgesDeferringSystemGestures
    }
}

/// The screens of the app's navigation stack these tests move between.
private struct PlayStack: View {
    @State var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            Color.clear.navigationDestination(for: Route.self) { route in
                switch route {
                case .play(let path): PlayView(packPath: path)
                case .midiSelect: MidiSelectView()
                default: EmptyView()
                }
            }
        }
        .environment(router)
    }
}
#endif
