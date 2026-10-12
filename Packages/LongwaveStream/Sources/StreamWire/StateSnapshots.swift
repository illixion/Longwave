// STATE frames (sections 4.1, 4.3, 4.7): unreliable, latest-wins snapshots.

/// Snapshot kinds. Open: a receiver skips a kind it doesn't know.
public struct StateKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let pointerAbsolute = StateKind(rawValue: 1)
    public static let pointerRelative = StateKind(rawValue: 2)
    public static let gamepad = StateKind(rawValue: 3)
    public static let headPose = StateKind(rawValue: 4)
}

/// Pointer position in a stream's pixel space (v2's `windowMouseMove`).
public struct PointerPosition: Sendable, Hashable {
    public static let wireSize = 8

    public var streamID: UInt32
    public var x: UInt16
    public var y: UInt16

    public init(streamID: UInt32, x: UInt16, y: UInt16) {
        self.streamID = streamID
        self.x = x
        self.y = y
    }
}

/// Relative pointer motion for pointer-lock games, as running totals since
/// the session started in 1/256 of a host pixel, wrapping. The host applies
/// the difference from the last total it saw (wrapping subtraction), so a lost
/// snapshot delays motion but never drops it, with no acknowledgement needed.
public struct RelativePointer: Sendable, Hashable {
    public static let wireSize = 8
    public static let unitsPerPixel: Int32 = 256

    public var totalX: Int32
    public var totalY: Int32

    public init(totalX: Int32, totalY: Int32) {
        self.totalX = totalX
        self.totalY = totalY
    }

    /// Motion from `previous` to `self`, in wire units.
    public func delta(since previous: RelativePointer) -> (x: Int32, y: Int32) {
        (totalX &- previous.totalX, totalY &- previous.totalY)
    }
}

/// Buttons by position (south = Xbox A / PlayStation cross / Nintendo B).
public struct GamepadButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let south = GamepadButtons(rawValue: 1 << 0)
    public static let east = GamepadButtons(rawValue: 1 << 1)
    public static let west = GamepadButtons(rawValue: 1 << 2)
    public static let north = GamepadButtons(rawValue: 1 << 3)
    public static let leftShoulder = GamepadButtons(rawValue: 1 << 4)
    public static let rightShoulder = GamepadButtons(rawValue: 1 << 5)
    public static let leftStick = GamepadButtons(rawValue: 1 << 6)
    public static let rightStick = GamepadButtons(rawValue: 1 << 7)
    public static let menu = GamepadButtons(rawValue: 1 << 8)
    public static let view = GamepadButtons(rawValue: 1 << 9)
    public static let home = GamepadButtons(rawValue: 1 << 10)
    public static let dpadUp = GamepadButtons(rawValue: 1 << 11)
    public static let dpadDown = GamepadButtons(rawValue: 1 << 12)
    public static let dpadLeft = GamepadButtons(rawValue: 1 << 13)
    public static let dpadRight = GamepadButtons(rawValue: 1 << 14)
    public static let share = GamepadButtons(rawValue: 1 << 15)
    public static let touchpadClick = GamepadButtons(rawValue: 1 << 16)
    public static let paddle1 = GamepadButtons(rawValue: 1 << 17)
    public static let paddle2 = GamepadButtons(rawValue: 1 << 18)
    public static let paddle3 = GamepadButtons(rawValue: 1 << 19)
    public static let paddle4 = GamepadButtons(rawValue: 1 << 20)

    public static let defined = GamepadButtons(rawValue: (1 << 21) - 1)
}

/// Gyro in rad/s and accelerometer in g, the pad's own axes (GameController's
/// convention).
public struct GamepadMotion: Sendable, Hashable {
    public static let wireSize = 24

    public var rotationRate: Vector3
    public var acceleration: Vector3

    public init(rotationRate: Vector3, acceleration: Vector3) {
        self.rotationRate = rotationRate
        self.acceleration = acceleration
    }
}

/// One touchpad contact; position normalised to 0...65535 across the pad.
public struct TouchpadContact: Sendable, Hashable {
    public var id: UInt8
    public var x: UInt16
    public var y: UInt16

    public init(id: UInt8, x: UInt16, y: UInt16) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// A full pad snapshot. Sticks are -32768...32767 with +Y up (XInput and
/// GameController agree); triggers 0...65535.
///
/// ```
///  0  u32  buttons            GamepadButtons; bits 21-31 reserved
///  4  i16  leftX, leftY, rightX, rightY
/// 12  u16  leftTrigger, rightTrigger
/// 16  u8   sections           bit 0 motion, bit 1 touchpad; others reserved
/// 17  24   motion             if bit 0: gyro x y z, accel x y z (f32)
///  .  12   touchpad           if bit 1: two contacts of
///                             (flags u8 bit 0 active, id u8, x u16, y u16);
///                             an inactive contact is all zero
/// ```
public struct GamepadState: Sendable, Hashable {
    public var buttons: GamepadButtons
    public var leftX: Int16
    public var leftY: Int16
    public var rightX: Int16
    public var rightY: Int16
    public var leftTrigger: UInt16
    public var rightTrigger: UInt16
    public var motion: GamepadMotion?
    /// Nil if the pad has no touchpad; otherwise up to two contacts.
    public var touchpad: [TouchpadContact]?

    public init(buttons: GamepadButtons = [], leftX: Int16 = 0, leftY: Int16 = 0, rightX: Int16 = 0, rightY: Int16 = 0,
                leftTrigger: UInt16 = 0, rightTrigger: UInt16 = 0, motion: GamepadMotion? = nil,
                touchpad: [TouchpadContact]? = nil) {
        self.buttons = buttons
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.motion = motion
        self.touchpad = touchpad
    }

    func validate() throws(WireError) {
        guard buttons.isSubset(of: .defined) else { throw .invalid("gamepad.buttons") }
        if let motion {
            guard motion.rotationRate.isFinite, motion.acceleration.isFinite else { throw .invalid("gamepad.motion") }
        }
        if let touchpad {
            guard touchpad.count <= 2 else { throw .tooLarge("gamepad.touchpad") }
        }
    }

    init(from reader: inout WireReader) throws(WireError) {
        buttons = GamepadButtons(rawValue: try reader.readUInt32())
        leftX = try reader.readInt16()
        leftY = try reader.readInt16()
        rightX = try reader.readInt16()
        rightY = try reader.readInt16()
        leftTrigger = try reader.readUInt16()
        rightTrigger = try reader.readUInt16()
        let sections = try reader.readUInt8()
        guard sections & ~0x03 == 0 else { throw .invalid("gamepad.sections") }
        motion = sections & 0x01 == 0 ? nil
            : GamepadMotion(rotationRate: try reader.readVector3(), acceleration: try reader.readVector3())
        if sections & 0x02 != 0 {
            var contacts: [TouchpadContact] = []
            var sawInactive = false
            for _ in 0..<2 {
                let flags = try reader.readUInt8()
                let contact = TouchpadContact(id: try reader.readUInt8(), x: try reader.readUInt16(), y: try reader.readUInt16())
                switch flags {
                case 1:
                    // Active contacts come first, so the encoding is canonical.
                    guard !sawInactive else { throw .invalid("gamepad.touchpad.order") }
                    contacts.append(contact)
                case 0:
                    guard contact == TouchpadContact(id: 0, x: 0, y: 0) else { throw .invalid("gamepad.touchpad.inactive") }
                    sawInactive = true
                default:
                    throw .invalid("gamepad.touchpad.flags")
                }
            }
            touchpad = contacts
        } else {
            touchpad = nil
        }
        try validate()
    }

    func encode(to writer: inout WireWriter) {
        writer.writeUInt32(buttons.rawValue)
        writer.writeInt16(leftX)
        writer.writeInt16(leftY)
        writer.writeInt16(rightX)
        writer.writeInt16(rightY)
        writer.writeUInt16(leftTrigger)
        writer.writeUInt16(rightTrigger)
        writer.writeUInt8((motion == nil ? 0 : 0x01) | (touchpad == nil ? 0 : 0x02))
        if let motion {
            writer.writeVector3(motion.rotationRate)
            writer.writeVector3(motion.acceleration)
        }
        if let touchpad {
            for slot in 0..<2 {
                if slot < touchpad.count {
                    let contact = touchpad[slot]
                    writer.writeUInt8(1)
                    writer.writeUInt8(contact.id)
                    writer.writeUInt16(contact.x)
                    writer.writeUInt16(contact.y)
                } else {
                    writer.writeBytes(repeatElement(UInt8(0), count: 6))
                }
            }
        }
    }
}

/// The gaze sample in a head-pose snapshot (valid only with `gaze` negotiated).
public struct GazeSample: Sendable, Hashable {
    /// Unit vector in head space.
    public var direction: Vector3
    /// Metres to the fixation point; 0 when unknown.
    public var distance: Float
    /// Host ns when the eyes were sampled.
    public var sampleTime: UInt64

    public init(direction: Vector3, distance: Float, sampleTime: UInt64) {
        self.direction = direction
        self.distance = distance
        self.sampleTime = sampleTime
    }

    func validate() throws(WireError) {
        guard direction.isFinite, abs(direction.lengthSquared - 1) <= 0.01 else { throw .invalid("headPose.gaze.direction") }
        guard distance.isFinite, distance >= 0 else { throw .invalid("headPose.gaze.distance") }
    }
}

/// The last PCVR frame the headset presented, for motion-to-photon.
public struct PresentedFrame: Sendable, Hashable {
    public var frameNumber: UInt32
    /// Host ns the frame reached the display.
    public var presentTime: UInt64

    public init(frameNumber: UInt32, presentTime: UInt64) {
        self.frameNumber = frameNumber
        self.presentTime = presentTime
    }
}

/// The PCVR uplink pose (section 4.7), sent at the display rate. 164 bytes:
///
/// ```
///   0  u64  displayTime        host ns this pose was predicted for
///   8  u16  spaceEpoch         bumped on recentre
///  10  u16  flags              bit 0 gaze valid, bit 1 presented frame valid
///  12  28   head               Pose in the immersive space
///  40  44   left eye           Pose relative to the head + FieldOfView
///  84  44   right eye
/// 128  u32  presentedFrame     } zero unless flag bit 1
/// 132  u64  presentTime        }
/// 140  12   gaze direction     } zero unless flag bit 0
/// 152  f32  gaze distance      }
/// 156  u64  gaze sample time   }
/// ```
///
/// Eye offsets and fields of view ride in every snapshot rather than only on
/// change: a STATE frame can be lost, and the host has to render with the
/// headset's current per-eye projection.
public struct HeadPose: Sendable, Hashable {
    public static let wireSize = 164

    public var displayTime: UInt64
    public var spaceEpoch: UInt16
    public var head: Pose
    public var leftEye: EyeView
    public var rightEye: EyeView
    public var presented: PresentedFrame?
    public var gaze: GazeSample?

    public init(displayTime: UInt64, spaceEpoch: UInt16, head: Pose, leftEye: EyeView, rightEye: EyeView,
                presented: PresentedFrame? = nil, gaze: GazeSample? = nil) {
        self.displayTime = displayTime
        self.spaceEpoch = spaceEpoch
        self.head = head
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.presented = presented
        self.gaze = gaze
    }

    func validate() throws(WireError) {
        try head.validate("headPose.head")
        try leftEye.validate("headPose.leftEye")
        try rightEye.validate("headPose.rightEye")
        try gaze?.validate()
    }

    init(from reader: inout WireReader) throws(WireError) {
        displayTime = try reader.readUInt64()
        spaceEpoch = try reader.readUInt16()
        let flags = try reader.readUInt16()
        guard flags & ~0x0003 == 0 else { throw .invalid("headPose.flags") }
        head = try reader.readPose()
        leftEye = try reader.readEyeView()
        rightEye = try reader.readEyeView()
        let frameNumber = try reader.readUInt32()
        let presentTime = try reader.readUInt64()
        if flags & 0x0002 != 0 {
            presented = PresentedFrame(frameNumber: frameNumber, presentTime: presentTime)
        } else {
            guard frameNumber == 0, presentTime == 0 else { throw .inconsistent("headPose.presented") }
            presented = nil
        }
        let direction = try reader.readVector3()
        let distance = try reader.readFloat32()
        let sampleTime = try reader.readUInt64()
        if flags & 0x0001 != 0 {
            gaze = GazeSample(direction: direction, distance: distance, sampleTime: sampleTime)
        } else {
            // Bit patterns, so -0.0 is rejected and no stale gaze leaks out.
            let floats = [direction.x, direction.y, direction.z, distance]
            guard floats.allSatisfy({ $0.bitPattern == 0 }), sampleTime == 0 else { throw .inconsistent("headPose.gaze") }
            gaze = nil
        }
        try validate()
    }

    func encode(to writer: inout WireWriter) {
        writer.writeUInt64(displayTime)
        writer.writeUInt16(spaceEpoch)
        writer.writeUInt16((gaze == nil ? 0 : 0x0001) | (presented == nil ? 0 : 0x0002))
        writer.writePose(head)
        writer.writeEyeView(leftEye)
        writer.writeEyeView(rightEye)
        writer.writeUInt32(presented?.frameNumber ?? 0)
        writer.writeUInt64(presented?.presentTime ?? 0)
        writer.writeVector3(gaze?.direction ?? .zero)
        writer.writeFloat32(gaze?.distance ?? 0)
        writer.writeUInt64(gaze?.sampleTime ?? 0)
    }
}

public enum StatePayload: Sendable, Hashable {
    case pointerAbsolute(PointerPosition)
    case pointerRelative(RelativePointer)
    case gamepad(GamepadState)
    case headPose(HeadPose)

    public var kind: StateKind {
        switch self {
        case .pointerAbsolute: .pointerAbsolute
        case .pointerRelative: .pointerRelative
        case .gamepad: .gamepad
        case .headPose: .headPose
        }
    }
}

/// Identifies one latest-wins series: a newer sequence number replaces an
/// older one only within the same key.
public struct StateKey: Sendable, Hashable {
    public var kind: StateKind
    public var source: UInt8

    public init(kind: StateKind, source: UInt8) {
        self.kind = kind
        self.source = source
    }
}

/// One STATE frame body: a 14-byte header, then the payload.
///
/// ```
///  0  u8   kind       StateKind
///  1  u8   source     gamepad index for .gamepad; 0 otherwise
///  2  u32  sequence   per (kind, source), wraps; latest wins (SerialNumber)
///  6  u64  hostTime   client's estimate of host time when sampled
/// 14  ...  payload    exactly the kind's layout
/// ```
public struct StateSnapshot: Sendable, Hashable {
    public static let headerSize = 14

    public var source: UInt8
    public var sequence: UInt32
    public var hostTime: UInt64
    public var payload: StatePayload

    public init(source: UInt8 = 0, sequence: UInt32, hostTime: UInt64, payload: StatePayload) {
        self.source = source
        self.sequence = sequence
        self.hostTime = hostTime
        self.payload = payload
    }

    public var key: StateKey { StateKey(kind: payload.kind, source: source) }

    /// Whether this snapshot should replace `current` (same series, newer).
    public func supersedes(_ current: StateSnapshot) -> Bool {
        key == current.key && SerialNumber.isNewer(sequence, than: current.sequence)
    }

    public func validate() throws(WireError) {
        switch payload {
        case .gamepad(let state):
            guard source <= GamepadInfo.maxIndex else { throw .invalid("state.source") }
            try state.validate()
        case .headPose(let pose):
            guard source == 0 else { throw .invalid("state.source") }
            try pose.validate()
        case .pointerAbsolute, .pointerRelative:
            guard source == 0 else { throw .invalid("state.source") }
        }
    }

    public func encode(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt8(payload.kind.rawValue)
        writer.writeUInt8(source)
        writer.writeUInt32(sequence)
        writer.writeUInt64(hostTime)
        switch payload {
        case .pointerAbsolute(let p):
            writer.writeUInt32(p.streamID)
            writer.writeUInt16(p.x)
            writer.writeUInt16(p.y)
        case .pointerRelative(let r):
            writer.writeInt32(r.totalX)
            writer.writeInt32(r.totalY)
        case .gamepad(let state):
            state.encode(to: &writer)
        case .headPose(let pose):
            pose.encode(to: &writer)
        }
    }

    public func encoded() throws(WireError) -> [UInt8] {
        var writer = WireWriter(reservingCapacity: Self.headerSize + HeadPose.wireSize)
        try encode(to: &writer)
        return writer.bytes
    }

    /// Decodes a STATE frame body; nil for a kind this build doesn't know.
    public init?(frameBody: ArraySlice<UInt8>) throws(WireError) {
        var reader = WireReader(frameBody)
        let kind = StateKind(rawValue: try reader.readUInt8())
        source = try reader.readUInt8()
        sequence = try reader.readUInt32()
        hostTime = try reader.readUInt64()
        switch kind {
        case .pointerAbsolute:
            payload = .pointerAbsolute(PointerPosition(streamID: try reader.readUInt32(), x: try reader.readUInt16(),
                                                       y: try reader.readUInt16()))
        case .pointerRelative:
            payload = .pointerRelative(RelativePointer(totalX: try reader.readInt32(), totalY: try reader.readInt32()))
        case .gamepad:
            payload = .gamepad(try GamepadState(from: &reader))
        case .headPose:
            payload = .headPose(try HeadPose(from: &reader))
        default:
            return nil
        }
        try reader.finish()
        try validate()
    }

    public init?(frameBody: [UInt8]) throws(WireError) {
        try self.init(frameBody: frameBody[...])
    }
}
