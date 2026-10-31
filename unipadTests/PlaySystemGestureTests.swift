#if os(iOS)
import SwiftUI
import Testing
@testable import unipad

/// Near a screen edge the system holds a touch back until it has ruled out a system swipe, which
/// would make the pads beside that edge late. The delay needs a real touch to show, so these check
/// what the system reads: it starts at the window's root and follows the child each controller names.
extension PlayUsageRecordTests {
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
            try await settle(in: window) { $0 == .all }
            #expect(deferredEdges(in: window) == .all)
        }

        /// The top and bottom edges are the ones only the play screen defers. A navigation stack
        /// already defers the left and right ones by itself.
        private func expectSystemSwipes(in window: UIWindow) async throws {
            let swipes: UIRectEdge = [.top, .bottom]
            try await settle(in: window) { $0.isDisjoint(with: swipes) }
            #expect(deferredEdges(in: window).isDisjoint(with: swipes))
        }

        /// Waits for `edges` and for the push or pop to end: a stack loses a path change made during one.
        private func settle(in window: UIWindow, until edges: (UIRectEdge) -> Bool) async throws {
            try await PlayUsageScenario.waitWhile {
                !edges(deferredEdges(in: window)) || deferringController(in: window)?.transitionCoordinator != nil
            }
            #expect(deferringController(in: window)?.transitionCoordinator == nil)
        }

        private func deferredEdges(in window: UIWindow) -> UIRectEdge {
            deferringController(in: window)?.preferredScreenEdgesDeferringSystemGestures ?? []
        }

        private func deferringController(in window: UIWindow) -> UIViewController? {
            guard var controller = window.rootViewController else { return nil }
            while let child = controller.childForScreenEdgesDeferringSystemGestures { controller = child }
            return controller
        }
    }
}

/// The play screen in the app's navigation stack. Every other route opens a blank screen: these
/// tests only need something covering the play screen, and the real connection screen would
/// change the shared MIDI driver and close itself after five seconds.
private struct PlayStack: View {
    @State var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            Color.clear.navigationDestination(for: Route.self) { route in
                switch route {
                case .play(let path): PlayView(packPath: path)
                default: Color.clear
                }
            }
        }
        .environment(router)
    }
}
#endif
