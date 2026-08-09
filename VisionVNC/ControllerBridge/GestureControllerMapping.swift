//  GestureControllerMapping.swift
//
//  Per-finger pinch → virtual-controller-input mapping for the Controller Bridge.
//  Adapted from Spatialcraft's HandGestureMapping (which mapped pinches to game
//  PlayerActions); here the targets are VR controller inputs so the headset's hand
//  gestures can drive an emulated controller — making the physical Switch Pro
//  OPTIONAL. The host splits the resulting button mask across the two emulated
//  controllers by identity (A/B → right, X/Y → left), so the physical pinching hand
//  and the emulated controller side line up with the defaults below.
//
//  Deliberately flag-free (no ARKit / no FOVEATED_ENABLED, no protocol dependency)
//  so it stays pure and unit-testable in the default build, mirroring FoveatedEndpoint.
//  The engine that detects pinches (HandGestureEngine) and the packet wiring
//  (ControllerBridgeSender) are the gated, ARKit-touching halves.

import Foundation

/// Which hand a pinch comes from.
enum BridgeHand: String, Codable, Sendable, CaseIterable {
    case left, right
}

/// Thumb-to-fingertip pinch fingers. Left + index is reserved as the locomotion
/// joystick (mirrors a real controller's left stick) and never appears as a button.
enum BridgeFinger: Int, Codable, Sendable, CaseIterable {
    case index = 0, middle, ring, little
}

/// A virtual-controller input a finger pinch can drive. The side-dependent targets
/// (`trigger`, `grip`, `stickClick`) resolve to the L or R variant by the pinching
/// hand; face buttons / menu / system are absolute. `.none` = unassigned.
enum BridgeGestureTarget: String, Codable, Sendable, CaseIterable {
    case none
    case trigger        // this hand's trigger (analog full + ZL/ZR)
    case grip           // this hand's grip (L/R shoulder)
    case stickClick     // this hand's thumbstick click
    case aButton
    case bButton
    case xButton
    case yButton
    case menu           // + / Start
    case system         // Home

    var displayName: String {
        switch self {
        case .none:       return "Unassigned"
        case .trigger:    return "Trigger"
        case .grip:       return "Grip"
        case .stickClick: return "Stick Click"
        case .aButton:    return "A"
        case .bButton:    return "B"
        case .xButton:    return "X"
        case .yButton:    return "Y"
        case .menu:       return "Menu"
        case .system:     return "System"
        }
    }
}

/// Persisted map (hand × finger → target). Left + index is the locomotion joystick
/// and is always `.none` (rendered locked in settings). Defaults cover the minimal
/// set most games want — ABXY + both triggers + a menu button — mirrored to the
/// correct controller sides: right hand drives the right controller (A/B/R-trigger/
/// menu), left hand the left controller (X/Y/L-trigger), with left+index = movement.
struct GestureControllerMapping: Codable, Equatable, Sendable {
    // Right hand → right controller
    var rightIndex: BridgeGestureTarget
    var rightMiddle: BridgeGestureTarget
    var rightRing: BridgeGestureTarget
    var rightLittle: BridgeGestureTarget

    // Left hand → left controller (index reserved for the joystick — not stored)
    var leftMiddle: BridgeGestureTarget
    var leftRing: BridgeGestureTarget
    var leftLittle: BridgeGestureTarget

    static let defaults = GestureControllerMapping(
        rightIndex:  .trigger,   // right-hand tap = the primary trigger
        rightMiddle: .aButton,
        rightRing:   .bButton,
        rightLittle: .menu,
        leftMiddle:  .xButton,
        leftRing:    .yButton,
        leftLittle:  .trigger    // left trigger
    )

    /// Lookup by hand + finger. Left + index always returns `.none` (joystick reservation).
    func target(for hand: BridgeHand, finger: BridgeFinger) -> BridgeGestureTarget {
        switch (hand, finger) {
        case (.right, .index):  return rightIndex
        case (.right, .middle): return rightMiddle
        case (.right, .ring):   return rightRing
        case (.right, .little): return rightLittle
        case (.left,  .index):  return .none   // joystick reservation
        case (.left,  .middle): return leftMiddle
        case (.left,  .ring):   return leftRing
        case (.left,  .little): return leftLittle
        }
    }

    mutating func set(_ target: BridgeGestureTarget, for hand: BridgeHand, finger: BridgeFinger) {
        switch (hand, finger) {
        case (.right, .index):  rightIndex = target
        case (.right, .middle): rightMiddle = target
        case (.right, .ring):   rightRing = target
        case (.right, .little): rightLittle = target
        case (.left,  .index):  break          // locked — joystick reservation
        case (.left,  .middle): leftMiddle = target
        case (.left,  .ring):   leftRing = target
        case (.left,  .little): leftLittle = target
        }
    }
}

/// UserDefaults-backed persistence (one round-trip UI → storage → sender).
@MainActor
enum GestureControllerMappingStore {
    private static let defaultsKey = "visionvnc.foveated.gestureControllerMapping.v1"

    static func load() -> GestureControllerMapping {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let mapping = try? JSONDecoder().decode(GestureControllerMapping.self, from: data)
        else { return .defaults }
        return mapping
    }

    static func save(_ mapping: GestureControllerMapping) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
