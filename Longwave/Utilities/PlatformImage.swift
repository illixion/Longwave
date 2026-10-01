import SwiftUI

#if canImport(UIKit)
import UIKit
/// The platform bitmap-image type: `UIImage` on visionOS/iOS, `NSImage` on macOS.
/// Used for now-playing artwork that crosses the SwiftUI / MediaPlayer boundary.
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Image {
    /// Cross-platform `Image` initializer from a `PlatformImage`, hiding the
    /// `init(uiImage:)` / `init(nsImage:)` split.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
