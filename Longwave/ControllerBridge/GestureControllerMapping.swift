//  GestureControllerMapping.swift
//
//  Per-finger pinch → virtual-controller-input mapping for the Controller Bridge.
//  The *targets* below are this app's — VR controller inputs, so headset hand
//  gestures can drive an emulated controller and make the physical Switch Pro
//  OPTIONAL. The host splits the resulting button mask across the two emulated
//  controllers by identity (A/B → right, X/Y → left), so the physical pinching
//  hand and the emulated controller side line up with the defaults below.
//
//  The table AROUND those targets is no longer this app's. It was adapted from
//  Spatialcraft's HandGestureMapping (which bound pinches to game actions) and
//  stayed a line-for-line copy of it: eight slots, one reserved for the
//  locomotion joystick and rendered locked, Codable, persisted as one blob.
//  That now lives in RAVE Engine as RAVEFingerBindingTable, shared by both.
//
//  The stored key and encoded field names are unchanged, so existing user
//  bindings load exactly as before. This table never stored `leftIndex` — the
//  reserved slot was not a value it kept — and the shared decoder treats it as
//  optional for exactly that reason.
//
//  Still deliberately flag-free (no ARKit, no FOVEATED_ENABLED) so it stays
//  pure and unit-testable in the default build, and so it compiles into the Mac
//  target too. The engine that detects pinches and the packet wiring
//  (ControllerBridgeSender) are the gated, ARKit-touching halves.

import Foundation
import RAVEInput

/// Which hand a pinch comes from.
typealias BridgeHand = RAVEHandChirality

/// Thumb-to-fingertip pinch fingers. Left + index is reserved as the locomotion
/// joystick (mirrors a real controller's left stick) and never appears as a button.
typealias BridgeFinger = RAVEHandFinger

/// A virtual-controller input a finger pinch can drive. The side-dependent targets
/// (`trigger`, `grip`, `stickClick`) resolve to the L or R variant by the pinching
/// hand; face buttons / menu / system are absolute. `.none` = unassigned.
enum BridgeGestureTarget: String, Codable, Sendable, CaseIterable, RAVEBindableAction {
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

    static var unassigned: BridgeGestureTarget { .none }

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
typealias GestureControllerMapping = RAVEFingerBindingTable<BridgeGestureTarget>

extension RAVEFingerBindingTable where Action == BridgeGestureTarget {
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
        action(for: hand, finger: finger)
    }
}

/// UserDefaults-backed persistence (one round-trip UI → storage → sender).
@MainActor
enum GestureControllerMappingStore {
    private static let store = RAVEFingerBindingStore<BridgeGestureTarget>(
        key: "longwave.foveated.gestureControllerMapping.v1",
        fallback: .defaults
    )

    static func load() -> GestureControllerMapping { store.load() }
    static func save(_ mapping: GestureControllerMapping) { store.save(mapping) }
}
