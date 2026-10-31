//  ControllerBridgeProtocol.swift
//
//  Swift mirror of `OpenXRLayer/protocol/controller_bridge_protocol.h`
//  (the v2 packets and the v3 0x10 tracked controllers). The C header is the
//  authoritative contract shared with the host — the OpenXR API layer and the
//  session broker; this file reproduces the layout for the visionOS sender. The
//  fixed sizes here (120-byte input packet, 144-byte tracked controllers, 14-byte
//  haptic packet) MUST match the C `static_assert`s — if you change one, change
//  both. LongwaveTests pins the 0x10 bytes against the same golden vector the
//  host's bridge_tests decodes.
//
//  Gated behind FOVEATED_ENABLED (the controller bridge accompanies a PCVR
//  foveated session).

#if FOVEATED_ENABLED
import Foundation
import RAVEInput
import simd

enum ControllerBridgeProtocol {
    /// The version byte every v2-era packet carries. It cannot move: the sealed
    /// envelope, the library header and the rendezvous compare it for equality on
    /// both ends. Version bytes are per packet type — see `version3`.
    static let version: UInt8 = 2
    /// The first packet stamped v3 is 0x10 (`ControllerBridgeTrackedControllers`),
    /// sent only to a host whose rendezvous announces it.
    static let version3: UInt8 = 3
    static let portInput: UInt16 = 9520    // sender → driver
    static let portHaptic: UInt16 = 9521   // driver → sender (legacy UDP return path)
    /// TCP. Everything that is not hand tracking: the game library, the perf feed,
    /// alignment telemetry, haptics and debug tuning. See `BridgeControlLink`.
    static let portControl: UInt16 = 9523

    static let packetInputState: UInt8 = 0x03
    static let packetHaptic: UInt8 = 0x02
    static let packetHandJoints: UInt8 = 0x04
    static let packetHandJointsOne: UInt8 = 0x05
    static let packetHeadPose: UInt8 = 0x06
    static let packetTelemetry: UInt8 = 0x07    // host → headset, alignment readout
    static let packetDebugTune: UInt8 = 0x08    // headset → host, alignment nudges
    static let packetPerf: UInt8 = 0x0C         // host → headset, frame pacing + residual
    /// Reserved: the retired host-side desk-Quest status. Nothing sends it; the HUD
    /// reads the headset's own `RAVEQuestBridgeSource` instead.
    static let packetQuestStatusReserved: UInt8 = 0x0D
    static let packetBandwidth: UInt8 = 0x0E        // host → headset, monthly usage + thresholds
    static let packetBandwidthControl: UInt8 = 0x0F // headset → host, threshold edits + reset
    static let packetTrackedControllers: UInt8 = 0x10 // headset → host, v3, Sense / Quest Touch
    static let packetTrackers: UInt8 = 0x11           // host → headset, v3, the tracker hub's state
    static let packetTrackerCommand: UInt8 = 0x12     // headset → host, v3, one-shot per sequence
    static let trackersMaxDevices = 12   // CB_TRACKERS_MAX_DEVICES
    static let trackerKeyBytes = 32      // CB_TRACKER_KEY_BYTES
    static let perfFrameSlots = 32   // cb_perf_t.frame_us capacity
    static let handJointCount = 26   // XR_EXT_hand_tracking joint order

    /// The client-visible UUID of the opaque data channel the host's OpenXR
    /// API layer opens (`OpenXRLayer/src/data_channel.h`, `kBridgeChannelGuid`
    /// = XrGuid 56564342-0001-4C42-…). VERIFIED via CloudXR.js on the Quest 3
    /// (2026-07-03): NVIDIA serializes the Windows GUID in its native
    /// little-endian layout (Data1/2/3 byte-swapped, Data4 verbatim, same as
    /// `Guid.ToByteArray()`), so the wire/client UUID is this byte-swapped
    /// form. The manager still accepts a lone unmatched channel as a fallback
    /// in case Apple's framework re-normalizes the ID differently.
    static let channelUUID = UUID(uuidString: "42435656-0100-424C-A667-B7C337D5B253")!

    struct Flags: OptionSet {
        let rawValue: UInt32
        static let leftHandTracked  = Flags(rawValue: 1 << 0)
        static let rightHandTracked = Flags(rawValue: 1 << 1)
        /// The union of `leftGyroValid` / `rightGyroValid` — "is there controller
        /// motion at all", kept as one test.
        static let gyroValid        = Flags(rawValue: 1 << 2)
        static let controllerPresent = Flags(rawValue: 1 << 3)
        static let leftPinch        = Flags(rawValue: 1 << 4)
        static let rightPinch       = Flags(rawValue: 1 << 5)
        /// Which hand the controller's IMU is describing. We decide this because
        /// only we can see both wrists and the controller; the host reads these
        /// two bits and nothing else, since we zero `.gyro` on the unclaimed hand.
        static let leftGyroValid    = Flags(rawValue: 1 << 6)
        static let rightGyroValid   = Flags(rawValue: 1 << 7)
    }

    struct Buttons: OptionSet {
        let rawValue: UInt32
        static let a         = Buttons(rawValue: 1 << 0)
        static let b         = Buttons(rawValue: 1 << 1)
        static let x         = Buttons(rawValue: 1 << 2)
        static let y         = Buttons(rawValue: 1 << 3)
        static let l         = Buttons(rawValue: 1 << 4)
        static let r         = Buttons(rawValue: 1 << 5)
        static let zl        = Buttons(rawValue: 1 << 6)
        static let zr        = Buttons(rawValue: 1 << 7)
        static let minus     = Buttons(rawValue: 1 << 8)
        static let plus      = Buttons(rawValue: 1 << 9)
        static let lstick    = Buttons(rawValue: 1 << 10)
        static let rstick    = Buttons(rawValue: 1 << 11)
        static let home      = Buttons(rawValue: 1 << 12)
        static let capture   = Buttons(rawValue: 1 << 13)
        static let dpadUp    = Buttons(rawValue: 1 << 14)
        static let dpadDown  = Buttons(rawValue: 1 << 15)
        static let dpadLeft  = Buttons(rawValue: 1 << 16)
        static let dpadRight = Buttons(rawValue: 1 << 17)
    }
}

/// One hand's wrist pose plus the controller gyro routed to it.
struct ControllerBridgeHandPose {
    var position: SIMD3<Float> = .zero
    var orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var gyro: SIMD3<Float> = .zero

    static let identity = ControllerBridgeHandPose()
}

/// The full v2 input-state packet, ready to serialize and send.
struct ControllerBridgeInputState {
    var sequence: UInt8 = 0
    var flags: ControllerBridgeProtocol.Flags = []
    var left: ControllerBridgeHandPose = .identity
    var right: ControllerBridgeHandPose = .identity
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var buttons: ControllerBridgeProtocol.Buttons = []
    /// Per-hand wrist-tracking confidence, 0–255. Scored from the skeleton joints the
    /// grip pose is built from, so the host can weight its continuous Quest-calibration
    /// pairs by how much of the hand was actually seen. 0 means "not reported" on the
    /// wire, so senders floor a real score at 1.
    var leftConfidence: UInt8 = 0
    var rightConfidence: UInt8 = 0

    /// Serialize to the 120-byte little-endian wire format (`cb_input_state_t`).
    func encoded() -> Data {
        var d = Data(capacity: 120)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetInputState)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)           // off 1
        d.cb_appendUInt8(sequence)                                   // off 2
        d.cb_appendUInt8(0)                                          // off 3 reserved0
        d.cb_appendUInt32(flags.rawValue)                            // off 4
        d.cb_appendHand(left)                                        // off 8  (40 B)
        d.cb_appendHand(right)                                       // off 48 (40 B)
        d.cb_appendFloat(leftStick.x); d.cb_appendFloat(leftStick.y)    // off 88
        d.cb_appendFloat(rightStick.x); d.cb_appendFloat(rightStick.y)  // off 96
        d.cb_appendFloat(leftTrigger)                                // off 104
        d.cb_appendFloat(rightTrigger)                               // off 108
        d.cb_appendUInt32(buttons.rawValue)                          // off 112
        d.cb_appendUInt8(leftConfidence)                             // off 116
        d.cb_appendUInt8(rightConfidence)                            // off 117
        d.cb_appendUInt8(0); d.cb_appendUInt8(0)                     // off 118 reserved1
        assert(d.count == 120, "cb_input_state_t must serialize to 120 bytes, got \(d.count)")
        return d
    }
}

/// One hand-skeleton joint (`cb_hand_joint_t`, 32 bytes on the wire).
struct ControllerBridgeJoint {
    var position: SIMD3<Float> = .zero
    var orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var radius: Float = 0
}

/// The 0x04 hand-skeletons packet (`cb_hand_joints_t`, 1668 bytes): 26 joints per
/// hand in XR_EXT_hand_tracking order, headset world space, joint orientation
/// convention -Z along the bone toward the fingertip / +Y out of the back of the
/// hand (both chiralities un-mirrored). Absent hands serialize as zeroes with the
/// matching valid flag cleared.
struct ControllerBridgeHandJoints {
    var sequence: UInt8 = 0
    var left: [ControllerBridgeJoint]?    // exactly `handJointCount` when present
    var right: [ControllerBridgeJoint]?

    func encoded() -> Data {
        var d = Data(capacity: 1668)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetHandJoints)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)           // off 1
        d.cb_appendUInt8(sequence)                                   // off 2
        var flags: UInt8 = 0
        if left != nil { flags |= 1 << 0 }
        if right != nil { flags |= 1 << 1 }
        d.cb_appendUInt8(flags)                                      // off 3
        d.cb_appendJoints(left)                                      // off 4    (832 B)
        d.cb_appendJoints(right)                                     // off 836  (832 B)
        assert(d.count == 1668, "cb_hand_joints_t must serialize to 1668 bytes, got \(d.count)")
        return d
    }
}

/// The 0x05 single-hand skeleton packet (`cb_hand_joints_one_t`, 836 bytes).
/// This is the form actually sent: the CloudXR message channel delivers the
/// 120-byte input packets but drops the 1668-byte both-hands 0x04, so each
/// tracked hand ships separately.
struct ControllerBridgeHandJointsOne {
    var sequence: UInt8 = 0
    var hand: UInt8 = 0                    // 0 = left, 1 = right
    var joints: [ControllerBridgeJoint]    // exactly `handJointCount`

    func encoded() -> Data {
        var d = Data(capacity: 836)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetHandJointsOne)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)              // off 1
        d.cb_appendUInt8(sequence)                                      // off 2
        d.cb_appendUInt8(hand)                                          // off 3
        d.cb_appendJoints(joints)                                       // off 4 (832 B)
        assert(d.count == 836, "cb_hand_joints_one_t must serialize to 836 bytes, got \(d.count)")
        return d
    }
}

/// The 0x06 sender head pose (`cb_head_pose_t`, 32 bytes): the device's ARKit
/// head pose in the SAME world space as the hand packets, sent at input rate.
/// The host aligns coordinate spaces from it — ARKit's world origin and the
/// streaming runtime's tracking origin are not guaranteed to coincide.
struct ControllerBridgeHeadPose {
    var sequence: UInt8 = 0
    var position: SIMD3<Float> = .zero
    var orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    func encoded() -> Data {
        var d = Data(capacity: 32)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetHeadPose)   // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)          // off 1
        d.cb_appendUInt8(sequence)                                  // off 2
        d.cb_appendUInt8(0)                                         // off 3 reserved
        d.cb_appendFloat(position.x); d.cb_appendFloat(position.y); d.cb_appendFloat(position.z)
        d.cb_appendFloat(orientation.imag.x); d.cb_appendFloat(orientation.imag.y)
        d.cb_appendFloat(orientation.imag.z); d.cb_appendFloat(orientation.real)
        assert(d.count == 32, "cb_head_pose_t must serialize to 32 bytes, got \(d.count)")
        return d
    }
}

/// The 0x08 debug-tuning packet (`cb_debug_tune_t`, 36 bytes): live alignment
/// adjustments from the in-headset HUD. Offsets are in the viewer's yaw frame
/// (x = the user's right, y = up, z = backwards) and apply on top of whatever the host
/// solved, so a nudge means the same thing whichever way the user faces.
///
/// Purely a session diagnostic now. These used to be persisted per title, back when the
/// host estimated its ARKit→runtime transform and every game needed a measured correction
/// on top; the host takes wrists from the runtime's own action spaces instead, so a nudge
/// is a way to investigate a discrepancy, not a setting worth keeping.
struct ControllerBridgeDebugTune: Equatable {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let freezeSolver  = Flags(rawValue: 1 << 0)
        static let disableSolver = Flags(rawValue: 1 << 1)
        static let setPredict    = Flags(rawValue: 1 << 2)
        static let resolve       = Flags(rawValue: 1 << 3)
        /// Use the wrists we send even where the runtime has its own. The HUD's live
        /// A/B button is gone (the runtime source won, and its slot now switches
        /// controller emulation instead) — nothing sets this any more, but the bit is
        /// wire layout: the host still honors it, and `stopClient` sits above it.
        static let forceBridgeHands = Flags(rawValue: 1 << 4)
        /// One-shot: close whatever is submitting frames. Never stored, only inserted for
        /// a single packet (see `ControllerBridgeSender.requestStopActiveClient`).
        static let stopClient = Flags(rawValue: 1 << 5)
        /// Reserved, never set: the retired consent bit for the host consuming a
        /// desk-Quest's cleartext controllers. Consent is now simply whether this app
        /// listens for a Quest at all, and its controllers go out as 0x10. The bit
        /// stays wire layout — `desktopQuad` sits above it.
        static let retiredQuestControllers = Flags(rawValue: 1 << 6)
        /// Show the desktop panel in the home view. Latched, but the host acts on a
        /// *change* rather than on the value: the desktop companion holds the same
        /// setting, and this packet is resent a few times a second, so a latched value
        /// would stamp on anything changed at the PC. Kept in step with the host's own
        /// answer, which arrives back in the telemetry.
        static let desktopQuad = Flags(rawValue: 1 << 7)
    }

    var flags: Flags = []
    var offsetLeft: SIMD3<Float> = .zero
    var offsetRight: SIMD3<Float> = .zero
    var yawDegrees: Float = 0
    var handPredictMs: Float = 15

    func offset(for hand: BridgeHand) -> SIMD3<Float> {
        hand == .left ? offsetLeft : offsetRight
    }

    func encoded(sequence: UInt8) -> Data {
        var d = Data(capacity: 36)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetDebugTune)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)          // off 1
        d.cb_appendUInt8(sequence)                                  // off 2
        d.cb_appendUInt8(flags.rawValue)                            // off 3
        d.cb_appendFloat(offsetLeft.x); d.cb_appendFloat(offsetLeft.y)
        d.cb_appendFloat(offsetLeft.z)                              // off 4
        d.cb_appendFloat(offsetRight.x); d.cb_appendFloat(offsetRight.y)
        d.cb_appendFloat(offsetRight.z)                             // off 16
        d.cb_appendFloat(yawDegrees)                                // off 28
        d.cb_appendFloat(handPredictMs)                             // off 32
        assert(d.count == 36, "cb_debug_tune_t must serialize to 36 bytes, got \(d.count)")
        return d
    }
}

/// The 0x07 telemetry packet (`cb_telemetry_t`, 132 bytes) the host ships back ~5 Hz:
/// everything the alignment HUD needs to show what the host actually solved and how
/// fresh its input is. Ages arrive in milliseconds, with -1 meaning "never received".
struct ControllerBridgeTelemetry {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let originValid  = Flags(rawValue: 1 << 0)
        static let leftJoints   = Flags(rawValue: 1 << 1)
        static let rightJoints  = Flags(rawValue: 1 << 2)
        static let channel      = Flags(rawValue: 1 << 3)
        static let solverFrozen = Flags(rawValue: 1 << 4)
        static let solverOff    = Flags(rawValue: 1 << 5)
        /// The desktop panel is wanted. Not the same as visible: a game holding the
        /// session hides it, and it returns with the home view.
        static let desktopQuad  = Flags(rawValue: 1 << 6)
        /// The host is submitting ALPHA_BLEND: transparent pixels are arriving as holes
        /// in the frame, and only `.mixed` immersion composites them against the room.
        /// Reported, not acted on — immersion is settled before the session starts (see
        /// `FoveatedHostInfo`), and this arrives long after the space exists. It is the
        /// strongest statement of what the host is actually doing, though: the blend mode
        /// the runtime *accepted*, where the pre-connect answer is only what was intended.
        static let alphaBlend   = Flags(rawValue: 1 << 7)
    }

    var flags: Flags
    var originYawDegrees: Float
    var originTranslation: SIMD3<Float>
    var tuneOffsetLeft: SIMD3<Float>
    var tuneOffsetRight: SIMD3<Float>
    var tuneYawDegrees: Float
    var handPredictMs: Float
    var inputAgeMs: Float
    var leftJointsAgeMs: Float
    var rightJointsAgeMs: Float
    var headAgeMs: Float
    var fps: Float
    var eyeHeight: Float
    /// The host's own view of the head, in the streaming runtime's tracking space.
    var hostHeadPosition: SIMD3<Float>
    /// The last ARKit head pose we sent, echoed back — the other half of the solve.
    var senderHeadPosition: SIMD3<Float>
    /// Executable of the client whose frames are reaching us, nil when nothing submits.
    /// Per-title profiles are keyed off this (see GameProfiles).
    var activeClient: String?

    init?(_ data: Data) {
        guard data.count >= 132, data[data.startIndex] == ControllerBridgeProtocol.packetTelemetry
        else { return nil }
        let b = [UInt8](data)
        func f(_ o: Int) -> Float {
            Float(bitPattern: UInt32(b[o]) | (UInt32(b[o + 1]) << 8) |
                              (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24))
        }
        func v(_ o: Int) -> SIMD3<Float> { SIMD3(f(o), f(o + 4), f(o + 8)) }
        flags = Flags(rawValue: b[3])
        originYawDegrees = f(4)
        originTranslation = v(8)
        tuneOffsetLeft = v(20)
        tuneOffsetRight = v(32)
        tuneYawDegrees = f(44)
        handPredictMs = f(48)
        inputAgeMs = f(52)
        leftJointsAgeMs = f(56)
        rightJointsAgeMs = f(60)
        headAgeMs = f(64)
        fps = f(68)
        eyeHeight = f(72)
        hostHeadPosition = v(76)
        senderHeadPosition = v(88)
        let nameBytes = b[100..<132].prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        activeClient = name.isEmpty ? nil : name
    }
}

/// The 0x0C perf packet (`cb_perf_t`, 124 bytes) the host ships at 10 Hz: frame pacing,
/// pose-claim divergence, wrist shake, and how far the two hand-tracking sources
/// disagree. The frame periods arrive in consecutive batches so the HUD's graph can just
/// append them.
struct ControllerBridgePerf {
    struct Flags: OptionSet {
        let rawValue: UInt8
        /// The runtime's own wrists are reaching the host.
        static let runtimeHands = Flags(rawValue: 1 << 0)
        /// We asked the host to use ours instead.
        static let forcedBridge = Flags(rawValue: 1 << 1)
        /// The host's render loop had not completed a frame when this was built, so the
        /// numbers in it are the last ones measured rather than current ones. The packet
        /// is sent regardless: perf used to be emitted *from* the render loop, so a stall
        /// stopped the feed — and a stopped feed and a stalled host look identical on a
        /// HUD unless one of them says which it is.
        static let stalled = Flags(rawValue: 1 << 2)
    }

    var flags: Flags
    /// Mean time `xrWaitFrame` blocked over the packet's window. Near a full frame
    /// period means the runtime is pacing us; near zero means the loop free-runs.
    var waitBlockMs: Float
    /// Mean step between the runtime's predicted display times.
    var pdtStepMs: Float
    var claimDeviationDegrees: Float
    var claimDeviationMm: Float
    /// Worst gap this window between the wrist our ARKit solve produces and the one the
    /// runtime reports for the same hand — 0 when the two aren't both live.
    var solveMissMm: Float
    var solveMissDegrees: Float
    var runtimeGripFrames: UInt32
    var bridgeGripFrames: UInt32
    /// Consecutive frame periods in milliseconds, oldest first.
    var framePeriodsMs: [Float]
    /// Wrist shake per hand (index 0 = left), mean and worst, in millimetres. Measured on
    /// the pose the game receives as the second difference of position, so a fast smooth
    /// sweep reads as zero and a vibrating still hand does not.
    var jitterMm: SIMD2<Float>
    var jitterMaxMm: SIMD2<Float>
    /// Rate at which *new* game frames reached the compositor. The frame periods above are
    /// the compositor's own cadence, which stays pinned to the display however badly the
    /// game is doing — when this is lower, the difference is repeated frames.
    var clientFps: Float

    init?(_ data: Data) {
        guard data.count >= 124, data[data.startIndex] == ControllerBridgeProtocol.packetPerf
        else { return nil }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) |
            (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        func f(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        flags = Flags(rawValue: b[3])
        waitBlockMs = f(8)
        pdtStepMs = f(12)
        claimDeviationDegrees = f(16)
        claimDeviationMm = f(20)
        solveMissMm = f(24)
        solveMissDegrees = f(28)
        runtimeGripFrames = u32(32)
        bridgeGripFrames = u32(36)
        let count = min(Int(b[4]), ControllerBridgeProtocol.perfFrameSlots)
        framePeriodsMs = (0..<count).map { i in
            let o = 40 + i * 2
            return Float(UInt16(b[o]) | (UInt16(b[o + 1]) << 8)) / 1000
        }
        jitterMm = SIMD2(f(104), f(108))
        jitterMaxMm = SIMD2(f(112), f(116))
        clientFps = f(120)
    }
}

/// One side of the 0x10 packet (`cb_tracked_controller_t`, 64 bytes): a real controller
/// the headset already knows the pose of, registered in the same ARKit world as the 0x03
/// wrists and shaped as an OpenXR grip pose, plus the headset's verdict on whether it is
/// in the user's hand. See `TrackedControllerForwarding` for how one is filled.
struct ControllerBridgeTrackedController: Equatable {
    struct Flags: OptionSet, Equatable {
        let rawValue: UInt8
        static let present    = Flags(rawValue: 1 << 0)
        static let tracked    = Flags(rawValue: 1 << 1)
        static let inHand     = Flags(rawValue: 1 << 2)
        static let touchValid = Flags(rawValue: 1 << 3)
        static let angularVelocity = Flags(rawValue: 1 << 4)
    }
    enum Source: UInt8 {
        case unknown = 0
        case quest = 1
        case sense = 2
    }
    static let batteryUnknown: UInt8 = 0xFF

    var position: SIMD3<Float> = .zero
    var orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var angularVelocity: SIMD3<Float> = .zero
    var trigger: Float = 0
    var grip: Float = 0
    var stick: SIMD2<Float> = .zero
    /// `RAVEControllerButtons` raw value, bit for bit (`CB_TC_BTN_*`).
    var buttons: UInt32 = 0
    var flags: Flags = []
    var source: Source = .unknown
    var battery: UInt8 = ControllerBridgeTrackedController.batteryUnknown

    /// No controller on this side: every field zero except the identity rotation and
    /// the unknown battery, which is what the host reads as "leave this side alone".
    static let absent = ControllerBridgeTrackedController()

    /// Held and ready to override this side's controls.
    var isHeld: Bool { flags.isSuperset(of: [.present, .inHand]) }
    /// Held and tracked: overrides this side's pose too.
    var ownsPose: Bool { isHeld && flags.contains(.tracked) }
}

/// The 0x10 tracked-controllers packet (`cb_tracked_controllers_t`, 144 bytes, sealed,
/// latest-wins, v3). Sent beside 0x03 only to a host that announces
/// `ControllerBridgeRendezvous.acceptsTrackedControllers`.
struct ControllerBridgeTrackedControllers: Equatable {
    var sequence: UInt8 = 0
    /// Headset monotonic clock (mach-derived), nanoseconds.
    var timestampNs: UInt64 = 0
    var left: ControllerBridgeTrackedController = .absent
    var right: ControllerBridgeTrackedController = .absent

    subscript(hand: BridgeHand) -> ControllerBridgeTrackedController {
        get { hand == .left ? left : right }
        set { if hand == .left { left = newValue } else { right = newValue } }
    }

    static let size = 144

    func encoded() -> Data {
        var d = Data(capacity: Self.size)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetTrackedControllers)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version3)                  // off 1
        d.cb_appendUInt8(sequence)                                           // off 2
        d.cb_appendUInt8(0)                                                  // off 3 reserved0
        d.cb_appendUInt32(0)                                                 // off 4 reserved1
        d.cb_appendUInt64(timestampNs)                                       // off 8
        d.cb_appendTrackedController(left)                                   // off 16 (64 B)
        d.cb_appendTrackedController(right)                                  // off 80 (64 B)
        assert(d.count == Self.size,
               "cb_tracked_controllers_t must serialize to 144 bytes, got \(d.count)")
        return d
    }
}

/// The 0x0E bandwidth packet (`cb_bandwidth_t`, 16 bytes) the host ships at ~1 Hz:
/// its own measured egress for the current calendar month, plus whatever warning/stop
/// thresholds it's configured with. `usedGB` is cumulative across sessions — unlike
/// perf/telemetry above, this number does not reset when a session ends, only when the
/// month rolls over or the host's counter is explicitly reset. That makes `.warning`/
/// `.stop` level state, not edge state: they stay set for the rest of the month once
/// crossed. Reacting to "the flag is set" rather than "the flag just became set" will
/// re-fire on every reconnect for the rest of the month — see `PCVRBandwidthMonitor`,
/// which is where the edge-triggering actually lives; this struct is a plain decode.
struct ControllerBridgeBandwidth {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let enabled = Flags(rawValue: 1 << 0)
        static let warning = Flags(rawValue: 1 << 1)
        static let stop    = Flags(rawValue: 1 << 2)
        /// The host's state mailbox was missing, stale, or the wrong size this tick —
        /// these are the last-known values, not fresh ones.
        static let stale   = Flags(rawValue: 1 << 3)
    }

    var flags: Flags
    var usedGB: Float
    var warningThresholdGB: Float
    var stopThresholdGB: Float

    /// Plain constructor, for tests that build a packet directly rather than
    /// decoding one off the wire — the same reason `PCVRSessionLimiter.advance`
    /// takes plain booleans instead of a live manager.
    init(flags: Flags = [], usedGB: Float = 0, warningThresholdGB: Float = 0, stopThresholdGB: Float = 0) {
        self.flags = flags
        self.usedGB = usedGB
        self.warningThresholdGB = warningThresholdGB
        self.stopThresholdGB = stopThresholdGB
    }

    init?(_ data: Data) {
        guard data.count >= 16, data[data.startIndex] == ControllerBridgeProtocol.packetBandwidth
        else { return nil }
        let b = [UInt8](data)
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) |
            (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        func f(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        flags = Flags(rawValue: b[3])
        usedGB = f(4)
        warningThresholdGB = f(8)
        stopThresholdGB = f(12)
    }
}

/// The 0x0F bandwidth-control packet (`cb_bandwidth_control_t`, 12 bytes) the headset
/// sends to edit the host's thresholds or request a counter reset. `.enabled` is
/// latched, same as the debug-tune flags above — the last value seen is the host's
/// config until changed again. `.reset` is one-shot like `.stopClient`: the host must
/// act on it exactly once per new `sequence`, since this packet is resent on the same
/// cadence as everything else here and a resend of an old reset must not fire twice.
struct ControllerBridgeBandwidthControl: Equatable {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let enabled = Flags(rawValue: 1 << 0)
        static let reset   = Flags(rawValue: 1 << 1)
    }

    var flags: Flags = []
    var warningThresholdGB: Float = 60
    var stopThresholdGB: Float = 90

    func encoded(sequence: UInt8) -> Data {
        var d = Data(capacity: 12)
        d.cb_appendUInt8(ControllerBridgeProtocol.packetBandwidthControl)  // off 0
        d.cb_appendUInt8(ControllerBridgeProtocol.version)                // off 1
        d.cb_appendUInt8(sequence)                                        // off 2
        d.cb_appendUInt8(flags.rawValue)                                  // off 3
        d.cb_appendFloat(warningThresholdGB)                              // off 4
        d.cb_appendFloat(stopThresholdGB)                                 // off 8
        assert(d.count == 12, "cb_bandwidth_control_t must serialize to 12 bytes, got \(d.count)")
        return d
    }
}

// MARK: - Trackers (0x11 host → headset, 0x12 headset → host)

/// What the PC's tracker hub is for the person wearing the devices: every device, placed in
/// ARKit world (this headset's own world, so it can be drawn exactly where it is), and the
/// state of the alignment that puts it there. `cb_trackers_header_t` (24 bytes) followed by
/// `device_count` × `cb_tracker_device_t` (72 bytes), on the TCP control link, ~30 Hz.
/// `OpenXRLayer/protocol/controller_bridge_protocol.h` is the contract.
struct ControllerBridgeTrackerDevice: Equatable, Identifiable {
    struct Flags: OptionSet, Equatable {
        let rawValue: UInt8
        /// A fresh pose arrived within the last ~100 ms.
        static let tracked = Flags(rawValue: 1 << 0)
        /// `position` / `orientation` are valid in ARKit world.
        static let placed  = Flags(rawValue: 1 << 1)
        /// Its tracking space is aligned to ARKit world.
        static let aligned = Flags(rawValue: 1 << 2)
        static let held    = Flags(rawValue: 1 << 3)
        static let moving  = Flags(rawValue: 1 << 4)
        /// Aligned from last time, not yet confirmed this run.
        static let warm    = Flags(rawValue: 1 << 5)
    }
    /// Which outline is drawn. Never a trust decision.
    enum Kind: UInt8 {
        case other = 0, wand = 1, touch = 2, tracker = 3
    }
    static let batteryUnknown: UInt8 = 0xFF

    var key: String = ""
    var position: SIMD3<Float> = .zero
    var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    var speed: Float = 0
    var flags: Flags = []
    /// The table's role for it, `TrackerRole.rawValue`.
    var role: UInt8 = 0
    var kind: Kind = .other
    var battery: UInt8 = ControllerBridgeTrackerDevice.batteryUnknown
    /// 0 / 1 = this device is presenting that hand, -1 = neither.
    var ownsHand: Int8 = -1

    var id: String { key }
    var isPlaced: Bool { flags.contains(.placed) }
    var isTracked: Bool { flags.contains(.tracked) }
    var isAligned: Bool { flags.contains(.aligned) }
}

struct ControllerBridgeTrackers: Equatable {
    struct Flags: OptionSet, Equatable {
        let rawValue: UInt8
        /// The hub is waiting for, or running, an alignment.
        static let autoAlign = Flags(rawValue: 1 << 0)
        /// A source is running or a table is loaded.
        static let hubActive = Flags(rawValue: 1 << 1)
        /// The broker has the headset's hands to pair with.
        static let headValid = Flags(rawValue: 1 << 2)
    }
    enum AlignPhase: UInt8 {
        case idle = 0, waiting = 1, collecting = 2, done = 3
    }
    /// `CB_TRK_RESULT_*`.
    enum Result: UInt8 {
        case none = 0, ok = 1, refused = 2, unknown = 3
    }

    var sequence: UInt8 = 0
    var flags: Flags = []
    var ackSequence: UInt8 = 0
    var ackResult: Result = .none
    var alignPhase: AlignPhase = .idle
    /// Index into `devices`, nil when no device is being aligned.
    var alignDevice: Int?
    /// 0 left, 1 right, nil until a hand is matched.
    var alignHand: Int?
    var alignSamples: Int = 0
    var alignSpreadMeters: Float = 0
    var alignResidualMm: Float = 0
    var alignSpreadTargetMeters: Float = 0.25
    var devices: [ControllerBridgeTrackerDevice] = []

    static let headerSize = 24
    static let deviceSize = 72

    init() {}

    init?(_ data: Data) {
        guard data.count >= Self.headerSize,
              data[data.startIndex] == ControllerBridgeProtocol.packetTrackers else { return nil }
        let b = [UInt8](data)
        guard b[1] == ControllerBridgeProtocol.version3 else { return nil }
        let count = Int(b[3])
        guard count <= ControllerBridgeProtocol.trackersMaxDevices,
              b.count >= Self.headerSize + Self.deviceSize * count else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        func f(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        sequence = b[2]
        flags = Flags(rawValue: b[4])
        ackSequence = b[5]
        ackResult = Result(rawValue: b[6]) ?? .none
        alignPhase = AlignPhase(rawValue: b[7]) ?? .idle
        let device = Int(Int8(bitPattern: b[8]))
        alignDevice = device >= 0 && device < count ? device : nil
        let hand = Int(Int8(bitPattern: b[9]))
        alignHand = hand == 0 || hand == 1 ? hand : nil
        alignSamples = Int(b[10]) | (Int(b[11]) << 8)
        alignSpreadMeters = f(12)
        alignResidualMm = f(16)
        alignSpreadTargetMeters = f(20)
        devices.reserveCapacity(count)
        for i in 0..<count {
            let o = Self.headerSize + Self.deviceSize * i
            var d = ControllerBridgeTrackerDevice()
            let name = b[o..<(o + ControllerBridgeProtocol.trackerKeyBytes)].prefix { $0 != 0 }
            d.key = String(decoding: name, as: UTF8.self)
            d.position = SIMD3(f(o + 32), f(o + 36), f(o + 40))
            d.orientation = simd_quatf(ix: f(o + 44), iy: f(o + 48), iz: f(o + 52), r: f(o + 56))
            d.speed = f(o + 60)
            d.flags = .init(rawValue: b[o + 64])
            d.role = b[o + 65]
            d.kind = .init(rawValue: b[o + 66]) ?? .other
            d.battery = b[o + 67]
            d.ownsHand = Int8(bitPattern: b[o + 68])
            devices.append(d)
        }
    }

    /// Host-direction encoder. The headset never sends this; it exists for the tests
    /// (which pin the bytes against the host's) and the demo feed.
    func encoded() -> Data {
        var d = Data(capacity: Self.headerSize + Self.deviceSize * devices.count)
        d.append(ControllerBridgeProtocol.packetTrackers)                    // off 0
        d.append(ControllerBridgeProtocol.version3)                          // off 1
        d.append(sequence)                                                   // off 2
        d.append(UInt8(devices.count))                                       // off 3
        d.append(flags.rawValue)                                             // off 4
        d.append(ackSequence)                                                // off 5
        d.append(ackResult.rawValue)                                         // off 6
        d.append(alignPhase.rawValue)                                        // off 7
        d.append(UInt8(bitPattern: Int8(alignDevice ?? -1)))                 // off 8
        d.append(UInt8(bitPattern: Int8(alignHand ?? -1)))                   // off 9
        d.cb_appendUInt8(UInt8(alignSamples & 0xFF))                         // off 10
        d.cb_appendUInt8(UInt8((alignSamples >> 8) & 0xFF))
        d.cb_appendFloat(alignSpreadMeters)                                  // off 12
        d.cb_appendFloat(alignResidualMm)                                    // off 16
        d.cb_appendFloat(alignSpreadTargetMeters)                            // off 20
        for device in devices {
            var key = Array(device.key.utf8.prefix(ControllerBridgeProtocol.trackerKeyBytes - 1))
            key += [UInt8](repeating: 0, count: ControllerBridgeProtocol.trackerKeyBytes - key.count)
            d.append(contentsOf: key)                                        // off 0
            d.cb_appendFloat(device.position.x); d.cb_appendFloat(device.position.y)
            d.cb_appendFloat(device.position.z)                              // off 32
            d.cb_appendFloat(device.orientation.imag.x); d.cb_appendFloat(device.orientation.imag.y)
            d.cb_appendFloat(device.orientation.imag.z); d.cb_appendFloat(device.orientation.real) // off 44
            d.cb_appendFloat(device.speed)                                   // off 60
            d.append(device.flags.rawValue)                                  // off 64
            d.append(device.role)                                            // off 65
            d.append(device.kind.rawValue)                                   // off 66
            d.append(device.battery)                                         // off 67
            d.append(UInt8(bitPattern: device.ownsHand))                     // off 68
            d.append(contentsOf: [0, 0, 0])                                  // off 69
        }
        return d
    }
}

/// The 0x12 tracker command (`cb_tracker_command_t`, 40 bytes). One-shot per `sequence`:
/// the host runs it once per new value, and `TrackerCommandQueue` resends it until the
/// host's 0x11 acknowledges that sequence.
struct ControllerBridgeTrackerCommand: Equatable {
    enum Op: UInt8 {
        case alignStart = 1, alignStop = 2, reset = 3, assign = 4, unassign = 5, setAutoAlign = 6
    }
    /// `CB_TRKCMD_HAND_AUTO`: align with whichever hand the device moves with.
    static let handAuto: UInt8 = 0xFF

    var op: Op
    var arg: UInt8 = 0
    var key: String = ""

    func encoded(sequence: UInt8) -> Data {
        var d = Data(capacity: 40)
        d.append(ControllerBridgeProtocol.packetTrackerCommand)   // off 0
        d.append(ControllerBridgeProtocol.version3)               // off 1
        d.append(sequence)                                        // off 2
        d.append(op.rawValue)                                     // off 3
        d.append(arg)                                             // off 4
        d.append(contentsOf: [0, 0, 0])                           // off 5
        var bytes = Array(key.utf8.prefix(ControllerBridgeProtocol.trackerKeyBytes - 1))
        bytes += [UInt8](repeating: 0, count: ControllerBridgeProtocol.trackerKeyBytes - bytes.count)
        d.append(contentsOf: bytes)                               // off 8
        assert(d.count == 40, "cb_tracker_command_t must serialize to 40 bytes, got \(d.count)")
        return d
    }
}

/// The hub's `Role` enum order (`tracker_model.h`); the wire carries the raw value.
enum TrackerRole: UInt8, CaseIterable, Identifiable {
    case none = 0, leftHand, rightHand, chest, waist, leftShoulder, rightShoulder,
         leftElbow, rightElbow, leftWrist, rightWrist, leftKnee, rightKnee,
         leftAnkle, rightAnkle, leftFoot, rightFoot

    var id: UInt8 { rawValue }

    var label: String {
        switch self {
        case .none: "Not used"
        case .leftHand: "Left hand"
        case .rightHand: "Right hand"
        case .chest: "Chest"
        case .waist: "Waist"
        case .leftShoulder: "Left shoulder"
        case .rightShoulder: "Right shoulder"
        case .leftElbow: "Left elbow"
        case .rightElbow: "Right elbow"
        case .leftWrist: "Left wrist"
        case .rightWrist: "Right wrist"
        case .leftKnee: "Left knee"
        case .rightKnee: "Right knee"
        case .leftAnkle: "Left ankle"
        case .rightAnkle: "Right ankle"
        case .leftFoot: "Left foot"
        case .rightFoot: "Right foot"
        }
    }

    /// Roles a controller takes; the rest are body roles (one device each).
    var isHand: Bool { self == .leftHand || self == .rightHand }
}

/// Decoded haptic pulse (`cb_haptic_packet_t`, 14 bytes) received from the driver.
struct ControllerBridgeHaptic {
    var controller: UInt8   // 0 = left, 1 = right
    var duration: Float
    var frequency: Float
    var amplitude: Float

    init?(_ data: Data) {
        guard data.count >= 14, data[data.startIndex] == ControllerBridgeProtocol.packetHaptic else { return nil }
        let bytes = [UInt8](data)
        controller = bytes[1]
        duration  = Float(bitPattern: ControllerBridgeHaptic.u32(bytes, 2))
        frequency = Float(bitPattern: ControllerBridgeHaptic.u32(bytes, 6))
        amplitude = Float(bitPattern: ControllerBridgeHaptic.u32(bytes, 10))
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

private extension Data {
    mutating func cb_appendUInt8(_ v: UInt8) { append(v) }

    mutating func cb_appendUInt32(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func cb_appendFloat(_ v: Float) { cb_appendUInt32(v.bitPattern) }

    mutating func cb_appendUInt64(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    /// Matches `cb_tracked_controller_t` (64 bytes).
    mutating func cb_appendTrackedController(_ c: ControllerBridgeTrackedController) {
        cb_appendFloat(c.position.x); cb_appendFloat(c.position.y); cb_appendFloat(c.position.z)  // 0
        cb_appendFloat(c.orientation.imag.x); cb_appendFloat(c.orientation.imag.y)                // 12
        cb_appendFloat(c.orientation.imag.z); cb_appendFloat(c.orientation.real)
        cb_appendFloat(c.angularVelocity.x); cb_appendFloat(c.angularVelocity.y)                  // 28
        cb_appendFloat(c.angularVelocity.z)
        cb_appendFloat(c.trigger)                                                                 // 40
        cb_appendFloat(c.grip)                                                                    // 44
        cb_appendFloat(c.stick.x); cb_appendFloat(c.stick.y)                                      // 48
        cb_appendUInt32(c.buttons)                                                                // 56
        cb_appendUInt8(c.flags.rawValue)                                                          // 60
        cb_appendUInt8(c.source.rawValue)                                                         // 61
        cb_appendUInt8(c.battery)                                                                 // 62
        cb_appendUInt8(0)                                                                         // 63
    }

    /// pos[3], rot[4] (x,y,z,w), gyro[3] — matches `cb_hand_pose_t` (40 bytes).
    mutating func cb_appendHand(_ h: ControllerBridgeHandPose) {
        cb_appendFloat(h.position.x); cb_appendFloat(h.position.y); cb_appendFloat(h.position.z)
        cb_appendFloat(h.orientation.imag.x); cb_appendFloat(h.orientation.imag.y)
        cb_appendFloat(h.orientation.imag.z); cb_appendFloat(h.orientation.real)
        cb_appendFloat(h.gyro.x); cb_appendFloat(h.gyro.y); cb_appendFloat(h.gyro.z)
    }

    /// One hand's 26 joints — matches `cb_hand_joint_t[26]` (832 bytes); nil = zeroes.
    mutating func cb_appendJoints(_ joints: [ControllerBridgeJoint]?) {
        if let joints {
            assert(joints.count == ControllerBridgeProtocol.handJointCount)
            for j in joints {
                cb_appendFloat(j.position.x); cb_appendFloat(j.position.y); cb_appendFloat(j.position.z)
                cb_appendFloat(j.orientation.imag.x); cb_appendFloat(j.orientation.imag.y)
                cb_appendFloat(j.orientation.imag.z); cb_appendFloat(j.orientation.real)
                cb_appendFloat(j.radius)
            }
        } else {
            append(contentsOf: [UInt8](repeating: 0, count: ControllerBridgeProtocol.handJointCount * 32))
        }
    }
}
#endif
