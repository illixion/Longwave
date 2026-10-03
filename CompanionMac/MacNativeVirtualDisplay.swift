import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import ObjectiveC

/// A display the Mac renders for the headset alone — the piece that turns the
/// Native desktop stream into a Mac Virtual Display replacement.
///
/// Built on the same `CGVirtualDisplay` machinery Apple's own Mac Virtual
/// Display (`SidecarDisplayAgent`) uses, verified on macOS 27 from an
/// unentitled process: the display comes online with whatever mode list it is
/// handed, so an ultra-wide desktop needs no ultra-wide monitor, and the
/// `DisplayExclusiveMode` descriptor key makes WindowServer disconnect every
/// physical display for as long as the virtual one exists — exactly what Mac
/// Virtual Display does when the Mac's screen goes dark. Releasing the object
/// brings them back; so does the process dying, since WindowServer tears the
/// display down with its owning connection.
///
/// The classes ship in CoreGraphics without headers, so this talks to them
/// through the Objective-C runtime: KVC for properties, and IMP casts for the
/// two calls whose ownership (`alloc`/`init…`) or return type (`BOOL`) KVC and
/// `perform` cannot express safely.
final class MacNativeVirtualDisplay {
    struct Configuration: Equatable {
        /// Desktop size in points. The display is always HiDPI, so the pixel
        /// canvas is twice this; WindowServer adds the 1x variants itself.
        var pointSize: CGSize
        /// The headset's own top rate. A 60 Hz mode is offered beside it, so
        /// the display still comes up if WindowServer refuses 120.
        var refreshRate: Double = 120
        /// Disconnect every physical display while this one exists.
        var exclusive: Bool
    }

    enum Error: LocalizedError {
        case classUnavailable(String)
        case createFailed
        case settingsRejected
        case neverCameOnline

        var errorDescription: String? {
            switch self {
            case .classUnavailable(let name):
                return "This macOS does not provide \(name); virtual displays are unavailable."
            case .createFailed:
                return "WindowServer refused to create the virtual display."
            case .settingsRejected:
                return "WindowServer rejected the virtual display's mode list."
            case .neverCameOnline:
                return "The virtual display never came online."
            }
        }
    }

    let configuration: Configuration
    let displayID: CGDirectDisplayID
    private var display: NSObject?
    private var sleepAssertion: IOPMAssertionID = 0

    init(configuration: Configuration) throws {
        self.configuration = configuration

        let descriptor = try Self.instance(of: "CGVirtualDisplayDescriptor")
        descriptor.setValue("Longwave Display", forKey: "name")
        descriptor.setValue(NSNumber(value: Self.vendorID), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: Self.productID), forKey: "productID")
        // Arrangement and mode preferences are persisted by WindowServer per
        // vendor/product/serial, so a different size gets its own identity
        // and its own remembered layout.
        descriptor.setValue(NSNumber(value: Self.serial(for: configuration.pointSize)), forKey: "serialNum")
        descriptor.setValue(NSNumber(value: UInt32(configuration.pointSize.width) * 2), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: UInt32(configuration.pointSize.height) * 2), forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: Self.physicalSize(for: configuration.pointSize)), forKey: "sizeInMillimeters")
        // sRGB primaries: what the headset's decoder assumes anyway.
        descriptor.setValue(NSValue(point: CGPoint(x: 0.64, y: 0.33)), forKey: "redPrimary")
        descriptor.setValue(NSValue(point: CGPoint(x: 0.30, y: 0.60)), forKey: "greenPrimary")
        descriptor.setValue(NSValue(point: CGPoint(x: 0.15, y: 0.06)), forKey: "bluePrimary")
        descriptor.setValue(NSValue(point: CGPoint(x: 0.3127, y: 0.3290)), forKey: "whitePoint")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        if configuration.exclusive {
            descriptor.perform(
                NSSelectorFromString("setDisplayInfoValue:forKey:"),
                with: NSNumber(value: 1),
                with: "DisplayExclusiveMode"
            )
        }

        let displayClass = try Self.objcClass("CGVirtualDisplay")
        guard let display = Self.allocInit(displayClass, "initWithDescriptor:", argument: descriptor) else {
            throw Error.createFailed
        }
        self.display = display
        self.displayID = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        guard displayID != 0 else {
            self.display = nil
            throw Error.createFailed
        }

        let settings = try Self.instance(of: "CGVirtualDisplaySettings")
        settings.setValue(NSNumber(value: 1), forKey: "hiDPI")
        var modes = [try Self.mode(configuration)]
        if configuration.refreshRate != 60 {
            var fallback = configuration
            fallback.refreshRate = 60
            modes.append(try Self.mode(fallback))
        }
        settings.setValue(modes, forKey: "modes")
        guard Self.apply(settings, to: display) else {
            self.display = nil
            throw Error.settingsRejected
        }

        // The display is the whole point of being awake: without this the
        // idle timer sleeps the Mac's only remaining display and the capture
        // stops delivering frames. Mac Virtual Display holds the same one.
        IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Longwave is streaming a virtual display" as CFString,
            &sleepAssertion
        )
    }

    deinit {
        invalidate()
    }

    /// Removes the display. WindowServer reconnects the physical displays on
    /// its own when this one was exclusive.
    func invalidate() {
        display = nil
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    /// WindowServer brings the display up asynchronously — in a few
    /// milliseconds on its own, a few hundred when it is also disconnecting
    /// the physical displays. Capture cannot start until it is online.
    func waitUntilOnline(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while CGDisplayIsOnline(displayID) == 0 {
            guard ContinuousClock.now < deadline else { throw Error.neverCameOnline }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for WindowServer to finish removing a released display — about
    /// a third of a second when it was exclusive and the physical displays
    /// come back first. Gives up after `timeout`; the caller's next create
    /// then fails on its own and says so.
    static func waitUntilGone(_ displayID: CGDirectDisplayID, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now + timeout
        while onlineDisplays().contains(displayID), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Conflicts

    /// Why a virtual display must not be created right now, or `nil`.
    ///
    /// Mac Virtual Display owns the display stack while it is connected: its
    /// display is exclusive, so WindowServer defers every other display's
    /// connect and disconnect until it ends. A virtual display created in
    /// that state comes up alongside Mac VD's, and releasing it does nothing
    /// until the Mac VD session closes — so a stream that started this way
    /// leaves a ghost display behind, and an exclusive request would fight
    /// the user's own session. Two independent signals, either sufficient:
    /// the power assertion `SidecarDisplayAgent` holds for the whole session,
    /// and a Sidecar-identity display being the only one online (Mac VD is
    /// always exclusive; an iPad Sidecar display is not and coexists).
    static func activeSessionConflict() -> String? {
        if holdsMacVirtualDisplayAssertion() {
            return "Mac Virtual Display is connected"
        }
        let online = onlineDisplays()
        if online.count == 1, let only = online.first,
           CGDisplayVendorNumber(only) == sidecarVendor, CGDisplayModelNumber(only) == sidecarModel {
            return "Mac Virtual Display is connected"
        }
        return nil
    }

    /// The name `SidecarDisplayAgent` gives its PreventUserIdleDisplaySleep
    /// assertion while a Mac Virtual Display session is up (visible in
    /// `pmset -g assertions`).
    private static let macVirtualDisplayAssertion = "com.apple.sidecar.macVirtualDisplayPreventDisplaySleep"
    private static let sidecarVendor: UInt32 = 0x6161_706C  // "appl"
    private static let sidecarModel: UInt32 = 0x6950_6164   // "iPad"

    private static func holdsMacVirtualDisplayAssertion() -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [AnyHashable: Any] else {
            return false
        }
        for case let list as [[String: Any]] in byProcess.values {
            if list.contains(where: { ($0[kIOPMAssertionNameKey] as? String) == macVirtualDisplayAssertion }) {
                return true
            }
        }
        return false
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    // MARK: - Identity

    static let vendorID: UInt32 = 0x4C57  // "LW"
    private static let productID: UInt32 = 0x0001

    private static func serial(for size: CGSize) -> UInt32 {
        (UInt32(size.width) & 0xFFFF) << 16 | (UInt32(size.height) & 0xFFFF)
    }

    /// A plausible physical size at roughly 110 points per inch, so the
    /// desktop gets the same UI density as a typical external monitor.
    private static func physicalSize(for size: CGSize) -> CGSize {
        let millimetersPerPoint = 25.4 / 110
        return CGSize(width: size.width * millimetersPerPoint, height: size.height * millimetersPerPoint)
    }

    // MARK: - Runtime bridge

    private static func objcClass(_ name: String) throws -> AnyClass {
        guard let cls = NSClassFromString(name) else { throw Error.classUnavailable(name) }
        return cls
    }

    private static func instance(of name: String) throws -> NSObject {
        guard let cls = try objcClass(name) as? NSObject.Type else { throw Error.classUnavailable(name) }
        return cls.init()
    }

    private static func mode(_ configuration: Configuration) throws -> NSObject {
        let cls = try objcClass("CGVirtualDisplayMode")
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let allocated = alloc(cls),
              let method = class_getInstanceMethod(cls, selector) else {
            throw Error.classUnavailable("CGVirtualDisplayMode")
        }
        typealias Init = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let call = unsafeBitCast(method_getImplementation(method), to: Init.self)
        guard let mode = call(
            allocated.takeUnretainedValue(),
            selector,
            UInt32(configuration.pointSize.width),
            UInt32(configuration.pointSize.height),
            configuration.refreshRate
        )?.takeRetainedValue() as? NSObject else {
            throw Error.classUnavailable("CGVirtualDisplayMode")
        }
        return mode
    }

    /// `+alloc` followed by a one-argument `init…`, with the ownership done by
    /// hand: `alloc` hands over +1, the initializer consumes it and returns
    /// +1, and only the result is handed to ARC. Going through Swift's own
    /// `alloc` would leave ARC holding a reference the initializer already
    /// consumed.
    private static func allocInit(_ cls: AnyClass, _ initializer: String, argument: AnyObject) -> NSObject? {
        let selector = NSSelectorFromString(initializer)
        guard let allocated = alloc(cls), let method = class_getInstanceMethod(cls, selector) else { return nil }
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let call = unsafeBitCast(method_getImplementation(method), to: Init.self)
        return call(allocated.takeUnretainedValue(), selector, argument)?.takeRetainedValue() as? NSObject
    }

    private static func alloc(_ cls: AnyClass) -> Unmanaged<AnyObject>? {
        let selector = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Alloc.self)(cls, selector)
    }

    private static func apply(_ settings: NSObject, to display: NSObject) -> Bool {
        let selector = NSSelectorFromString("applySettings:")
        guard let method = class_getInstanceMethod(type(of: display), selector) else { return false }
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Apply.self)(display, selector, settings)
    }
}

/// Desktop sizes offered in the companion's Native pane. Points; the display
/// is HiDPI so each streams at twice this when the link allows.
enum MacNativeVirtualDisplayPreset: String, CaseIterable, Identifiable {
    case fullHD = "1920x1080"
    case qhd = "2560x1440"
    case wqxga = "2560x1600"
    case ultrawide = "3440x1440"
    case ultrawidePlus = "3840x1600"
    case superUltrawide = "5120x1440"
    case fiveK = "5120x2880"

    var id: String { rawValue }

    var pointSize: CGSize {
        let parts = rawValue.split(separator: "x").compactMap { Double($0) }
        return CGSize(width: parts[0], height: parts[1])
    }

    var title: String {
        switch self {
        case .fullHD: return "1920 × 1080"
        case .qhd: return "2560 × 1440"
        case .wqxga: return "2560 × 1600 (16:10)"
        case .ultrawide: return "3440 × 1440 (21:9)"
        case .ultrawidePlus: return "3840 × 1600 (24:10)"
        case .superUltrawide: return "5120 × 1440 (32:9)"
        case .fiveK: return "5120 × 2880 (5K)"
        }
    }
}
