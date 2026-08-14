//  ControllerBridgeProtocol.swift
//
//  Swift mirror of `OpenXRLayer/protocol/controller_bridge_protocol.h`
//  (the v2, 0x03 packet). The C header is the authoritative contract shared
//  with the host — the OpenXR API layer and the session broker; this file
//  reproduces the layout for the visionOS
//  sender. The fixed sizes here (120-byte input packet, 14-byte haptic packet)
//  MUST match the C `static_assert`s — if you change one, change both.
//
//  Gated behind FOVEATED_ENABLED (the controller bridge accompanies a PCVR
//  foveated session).

#if FOVEATED_ENABLED
import Foundation
import RAVEInput
import simd

enum ControllerBridgeProtocol {
    static let version: UInt8 = 2
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
    static let packetQuestStatus: UInt8 = 0x0D  // host → headset, desk-Quest calibration
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
        /// Consume the desk-Quest's cleartext controllers during this sealed session.
        /// The 0x01 path is unauthenticated by design, so the host holds those packets
        /// until WE — the authenticated peer — say they are ours. Latched.
        static let questControllers = Flags(rawValue: 1 << 6)
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

/// The 0x0D desk-Quest status (`cb_quest_status_t`, 28 bytes) the host ships at 10 Hz
/// while a QuestControllerBridge headset has been heard from. This is the feedback
/// side of broker-assisted calibration: the HUD renders these fields directly, from
/// "detected" through "collecting — keep moving" to "aligned ±N mm".
struct ControllerBridgeQuestStatus {
    enum State: UInt8 {
        case seen = 1          // packets arriving, not enabled by the user
        case collecting = 2    // enabled, gathering calibration pairs
        case calibrated = 3    // solved; poses are reaching the game
        case lost = 4          // enabled but the Quest's packets went stale
    }
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let leftTracked = Flags(rawValue: 1 << 0)
        static let rightTracked = Flags(rawValue: 1 << 1)
        /// The transform was restored from a previous run and fresh pairs have not
        /// confirmed it yet.
        static let warmStart = Flags(rawValue: 1 << 2)
        /// The Quest is able to read its controller batteries — see `batteryLeft`.
        static let battery = Flags(rawValue: 1 << 3)
    }

    var state: State
    var flags: Flags
    var sampleCount: Int
    var sampleTarget: Int
    /// Floor-plane extent of the collected samples vs what the solve needs — spread,
    /// not count, is what conditions the yaw, so "keep moving" is keyed to this.
    var spreadMeters: Float
    var spreadTargetMeters: Float
    /// RMS pair error after the solve; 0 until solved.
    var residualMm: Float
    var inputAgeMs: Float
    /// Controller battery percentage, or nil when that side's level is unknown —
    /// the controller is off, or the Quest app was never granted the permission it
    /// needs to look (there is no OpenXR API for this; it scrapes `dumpsys`). Both
    /// nil is therefore normal and means "show nothing", not "empty". Minutes stale
    /// by design: the Quest polls every 30 s.
    var batteryLeft: Int?
    var batteryRight: Int?

    init?(_ data: Data) {
        guard data.count >= 28,
              data[data.startIndex] == ControllerBridgeProtocol.packetQuestStatus
        else { return nil }
        let b = [UInt8](data)
        guard let parsed = State(rawValue: b[3]) else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) |
            (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        func f(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        state = parsed
        flags = Flags(rawValue: b[4])
        sampleCount = Int(UInt16(b[8]) | (UInt16(b[9]) << 8))
        sampleTarget = Int(UInt16(b[10]) | (UInt16(b[11]) << 8))
        spreadMeters = f(12)
        spreadTargetMeters = f(16)
        residualMm = f(20)
        inputAgeMs = f(24)
        func battery(_ o: Int) -> Int? {
            guard flags.contains(.battery), b[o] <= 100 else { return nil }
            return Int(b[o])
        }
        batteryLeft = battery(5)
        batteryRight = battery(6)
    }
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
