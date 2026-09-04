import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The name this device introduces itself with to a host — the Native stream's
/// hello, which the Mac companion shows in its "connected"/"replaced by"
/// notifications.
enum DeviceName {
    static var current: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}
