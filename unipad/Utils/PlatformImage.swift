#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

import SwiftUI

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    @ViewBuilder
    func platformNavigationBarHidden(_ hidden: Bool) -> some View {
        #if canImport(UIKit)
        self.navigationBarHidden(hidden)
        #else
        self
        #endif
    }

    /// Keeps a header drawn at the top of a screen out from under the window controls
    /// iPadOS 26 puts in a resized window's top leading corner, where a touch would
    /// reach them instead of the header. Nothing moves where the corner is free.
    @ViewBuilder
    func avoidingWindowControls() -> some View {
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            self.containerCornerOffset(.leading, sizeToFit: true)
        } else {
            self
        }
    }

    @ViewBuilder
    func platformNavigationBarTitleDisplayMode() -> some View {
        #if canImport(UIKit)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

enum PlatformHelpers {
    static func openURL(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

enum PlatformPasteboard {
    static func copyString(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
