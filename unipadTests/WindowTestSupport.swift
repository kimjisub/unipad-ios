#if os(iOS)
import SwiftUI
import Testing

extension UIWindow {
    /// A window of the test app's scene showing `root`. The caller hides it when done.
    static func showing(_ root: some View, frame: CGRect? = nil) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        if let frame { window.frame = frame }
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        return window
    }
}
#endif
