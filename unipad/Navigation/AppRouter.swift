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

        guard url.startAccessingSecurityScopedResource() else {
            NotificationCenter.default.post(
                name: NSNotification.Name("UniPadExternalFileImportFailed"),
                object: nil,
                userInfo: ["error": "파일 접근 권한을 얻을 수 없습니다"]
            )
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let zipData = try Data(contentsOf: url)

            Task { @MainActor in
                await importFileData(zipData, fileName: fileName)
            }
        } catch {
            NotificationCenter.default.post(
                name: NSNotification.Name("UniPadExternalFileImportFailed"),
                object: nil,
                userInfo: ["error": error.localizedDescription]
            )
        }
    }

    @MainActor
    private func importFileData(_ data: Data, fileName: String) async {
        let workspace = WorkspaceManager.shared.downloadWorkspace.url
        let importer = UniPackImporter()

        do {
            await importer.importPack(data: data, fileName: fileName, to: workspace, delegate: nil)

            NotificationCenter.default.post(
                name: NSNotification.Name("UniPadExternalFileImported"),
                object: nil
            )
        } catch {
            NotificationCenter.default.post(
                name: NSNotification.Name("UniPadExternalFileImportFailed"),
                object: nil,
                userInfo: ["error": error.localizedDescription]
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
