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

    func navigateToMidiSelectIfNeeded() {
        guard !isShowingMidiSelect else { return }
        navigate(to: .midiSelect)
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
        if url.scheme == "file" {
            handleFileOpen(url)
        } else if url.scheme == "unipad" {
            handleUnipadScheme(url)
        }
    }

    private func handleFileOpen(_ url: URL) {
        let fileName = url.lastPathComponent
        guard fileName.lowercased().hasSuffix(".zip") else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("UniPadFileOpenRequest"),
                object: nil,
                userInfo: ["url": url, "fileName": fileName]
            )
        }
    }

    private func handleUnipadScheme(_ url: URL) {
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
