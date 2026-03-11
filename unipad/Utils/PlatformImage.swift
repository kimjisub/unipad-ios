#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

#if canImport(AppKit) && !canImport(UIKit)
extension NSImage {
    convenience init?(named name: String) {
        self.init(named: NSImage.Name(name))
    }
}
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
