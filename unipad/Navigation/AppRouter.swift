import SwiftUI

@Observable
final class AppRouter {
    var path = NavigationPath()
    var showSplash = true

    func navigate(to route: Route) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    func popToRoot() {
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
