import SwiftUI

@Observable
final class AppRouter {
    var path = NavigationPath()
    private(set) var routeStack: [Route] = []
    var showSplash = true

    var currentRoute: Route {
        routeStack.last ?? .main
    }

    var isShowingMidiSelect: Bool {
        if case .midiSelect = currentRoute {
            return true
        }
        return false
    }

    func navigate(to route: Route) {
        routeStack.append(route)
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        if !routeStack.isEmpty {
            routeStack.removeLast()
        }
        path.removeLast()
    }

    func popToRoot() {
        routeStack.removeAll()
        path = NavigationPath()
    }

    func dismissSplash() {
        withAnimation(.easeOut(duration: 0.3)) {
            showSplash = false
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "unipad" else { return }

        switch url.host {
        case "play":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
               !path.isEmpty {
                navigate(to: .play(packPath: path))
            }
        case "unipack":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
               !code.isEmpty {
                navigate(to: .importByUrl(code: code))
            }
        default:
            break
        }
    }
}
