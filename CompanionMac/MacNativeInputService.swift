import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Lets a paired Vision Pro move the pointer, click/drag/scroll, and — when
/// explicitly allowed — type modifier shortcuts and special keys on this Mac
/// while viewing its Screen stream. Mouse and keyboard-*shortcut* control are
/// two independent, off-by-default toggles (mirroring `InjectionService`'s
/// "the user opts in" convention): mouse has no restricted fallback, but
/// keyboard shortcuts do — printable typing keeps working through the
/// existing text-only `CompanionInjectProtocol` channel regardless of this
/// toggle (see `MacNativeStreamManager`), the same modifier-safe channel VNC
/// typing already uses. Posting requires the Accessibility
/// (`AXIsProcessTrusted`) permission, same as text injection.
@Observable
final class MacNativeInputService {
    /// Mouse master switch, persisted. Off by default — the user opts in.
    var mouseControlEnabled: Bool {
        get {
            access(keyPath: \.mouseControlEnabled)
            return UserDefaults.standard.bool(forKey: "macNativeMouseControlEnabled")
        }
        set {
            withMutation(keyPath: \.mouseControlEnabled) {
                UserDefaults.standard.set(newValue, forKey: "macNativeMouseControlEnabled")
            }
        }
    }

    /// Keyboard-*shortcuts* master switch (full keycode + modifiers),
    /// persisted. Off by default — the user opts in. Independent of
    /// `InjectionService.injectionEnabled`, which governs the always-attempted
    /// text-only fallback typing keeps working through when this is off.
    var keyboardShortcutsEnabled: Bool {
        get {
            access(keyPath: \.keyboardShortcutsEnabled)
            return UserDefaults.standard.bool(forKey: "macNativeKeyboardShortcutsEnabled")
        }
        set {
            withMutation(keyPath: \.keyboardShortcutsEnabled) {
                UserDefaults.standard.set(newValue, forKey: "macNativeKeyboardShortcutsEnabled")
            }
        }
    }

    /// Whether this process holds the Accessibility permission — shared by
    /// both capabilities (and by `InjectionService`), since it's the same
    /// CGEvent-posting permission underneath all three.
    private(set) var accessibilityTrusted = AXIsProcessTrusted()

    var isMouseAvailable: Bool { mouseControlEnabled && accessibilityTrusted }
    var isKeyboardShortcutsAvailable: Bool { keyboardShortcutsEnabled && accessibilityTrusted }

    /// Current mouse availability as the wire `RemoteControlStatus` byte.
    var mouseStatusByte: UInt8 {
        if !mouseControlEnabled { return MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue }
        return (accessibilityTrusted ? MacNativeStreamProtocol.RemoteControlStatus.available
                                     : MacNativeStreamProtocol.RemoteControlStatus.accessibilityDenied).rawValue
    }

    /// Current keyboard-shortcuts availability as the wire `RemoteControlStatus` byte.
    var keyboardStatusByte: UInt8 {
        if !keyboardShortcutsEnabled { return MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue }
        return (accessibilityTrusted ? MacNativeStreamProtocol.RemoteControlStatus.available
                                     : MacNativeStreamProtocol.RemoteControlStatus.accessibilityDenied).rawValue
    }

    func refreshAccessibility() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Re-checks Accessibility, prompting the user to grant it if missing.
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        accessibilityTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Pointer

    /// The button currently held down (if any) — a subsequent move is posted
    /// as a "dragged" event of that button instead of a plain move, so the
    /// wire protocol only needs move/down/up, not a separate drag frame.
    private var activeButton: MacNativeStreamProtocol.MouseButton?
    private var lastClickTime: [MacNativeStreamProtocol.MouseButton: Date] = [:]
    private var lastClickLocation: [MacNativeStreamProtocol.MouseButton: CGPoint] = [:]
    private var clickCounts: [MacNativeStreamProtocol.MouseButton: Int] = [:]

    func moveMouse(to point: CGPoint) {
        guard isMouseAvailable else { return }
        if let activeButton {
            postMouse(type: dragType(for: activeButton), point: point, button: activeButton, clickCount: 1)
        } else {
            postMouse(type: .mouseMoved, point: point, button: .left, clickCount: 0)
        }
    }

    func mouseDown(button: MacNativeStreamProtocol.MouseButton, at point: CGPoint) {
        guard isMouseAvailable else { return }
        activeButton = button
        let clickCount = registerClick(button: button, at: point)
        postMouse(type: downType(for: button), point: point, button: button, clickCount: clickCount)
    }

    func mouseUp(button: MacNativeStreamProtocol.MouseButton, at point: CGPoint) {
        guard isMouseAvailable else { return }
        if activeButton == button { activeButton = nil }
        let clickCount = clickCounts[button] ?? 1
        postMouse(type: upType(for: button), point: point, button: button, clickCount: clickCount)
    }

    func scroll(deltaX: Int32, deltaY: Int32, at point: CGPoint) {
        guard isMouseAvailable else { return }
        // Move the pointer under the scroll target first so the event lands
        // in the intended view, matching real trackpad behavior.
        postMouse(type: .mouseMoved, point: point, button: .left, clickCount: 0)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    func keyDown(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        guard isKeyboardShortcutsAvailable else { return }
        postKey(keyCode: CGKeyCode(keyCode), isDown: true, modifiers: modifiers.cgEventFlags)
    }

    func keyUp(keyCode: UInt16, modifiers: MacNativeKeyModifiers) {
        guard isKeyboardShortcutsAvailable else { return }
        postKey(keyCode: CGKeyCode(keyCode), isDown: false, modifiers: modifiers.cgEventFlags)
    }

    // MARK: - Private

    private func postMouse(
        type: CGEventType,
        point: CGPoint,
        button: MacNativeStreamProtocol.MouseButton,
        clickCount: Int
    ) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: cgButton(for: button)
        ) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postKey(keyCode: CGKeyCode, isDown: Bool, modifiers: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }
        event.flags = modifiers
        event.post(tap: .cghidEventTap)
    }

    private func cgButton(for button: MacNativeStreamProtocol.MouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .other: return .center
        }
    }

    private func downType(for button: MacNativeStreamProtocol.MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .other: return .otherMouseDown
        }
    }

    private func upType(for button: MacNativeStreamProtocol.MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .other: return .otherMouseUp
        }
    }

    private func dragType(for button: MacNativeStreamProtocol.MouseButton) -> CGEventType {
        switch button {
        case .left: return .leftMouseDragged
        case .right: return .rightMouseDragged
        case .other: return .otherMouseDragged
        }
    }

    /// macOS-style double/triple-click detection: same button, same spot
    /// (within a few points), within the system double-click interval.
    private func registerClick(button: MacNativeStreamProtocol.MouseButton, at point: CGPoint) -> Int {
        let now = Date()
        let previousTime = lastClickTime[button]
        let previousLocation = lastClickLocation[button] ?? .zero
        let closeEnough = abs(point.x - previousLocation.x) < 4 && abs(point.y - previousLocation.y) < 4
        if let previousTime, now.timeIntervalSince(previousTime) < NSEvent.doubleClickInterval, closeEnough {
            clickCounts[button] = (clickCounts[button] ?? 1) + 1
        } else {
            clickCounts[button] = 1
        }
        lastClickTime[button] = now
        lastClickLocation[button] = point
        return clickCounts[button] ?? 1
    }
}
