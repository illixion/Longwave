import Foundation
import AppKit
import CoreGraphics

/// The Mac's physical displays as the desktop-stream picker sees them.
///
/// Identified by display UUID rather than `CGDirectDisplayID`: the ID is
/// reassigned on reconnect and across reboots, the UUID is not, and a choice
/// made last week should still mean the same monitor.
enum MacNativeDisplayCatalog {
    /// Online physical displays, main first. Excludes the companion's own
    /// virtual display — the picker lists that separately.
    static func physicalDisplays() -> [MacNativeStreamProtocol.DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let names = screenNames()
        let main = CGMainDisplayID()
        return ids.prefix(Int(count))
            .filter { CGDisplayVendorNumber($0) != MacNativeVirtualDisplay.vendorID }
            .sorted { ($0 == main ? 0 : 1, $0) < ($1 == main ? 0 : 1, $1) }
            .compactMap { id in
                guard let uuid = uuidString(for: id) else { return nil }
                let bounds = CGDisplayBounds(id)
                let fallback = CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
                return .init(
                    id: uuid,
                    name: names[id] ?? fallback,
                    isVirtual: false,
                    width: bounds.width,
                    height: bounds.height
                )
            }
    }

    static func mainDisplayUUID() -> String? {
        uuidString(for: CGMainDisplayID())
    }

    /// The live ID for a stored UUID; nil when no display has it.
    static func displayID(forUUID uuidString: String) -> CGDirectDisplayID? {
        guard let uuid = CFUUIDCreateFromString(nil, uuidString as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        return id == 0 ? nil : id
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }
}
