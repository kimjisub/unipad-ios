#if (DEBUG || UNIPAD_RELEASE_TESTS) && canImport(UIKit)
import SwiftUI
import UIKit

/// Reads live UIKit state for lifecycle tests; a foreground process may still be inactive.
/// The view is installed only for an isolated test library that explicitly requests it.
struct ReleaseTestActivationView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = ActivationValueView(frame: .zero)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "test.appInputReadiness"
        view.accessibilityLabel = "App input readiness"
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class ActivationValueView: UIView {
        override var accessibilityValue: String? {
            get {
                let applicationActive = UIApplication.shared.applicationState == .active
                let sceneActive = window?.windowScene?.activationState == .foregroundActive
                return applicationActive && sceneActive ? "active" : "inactive"
            }
            set {} // UIKit supplies the value for each query.
        }
    }
}
#endif
