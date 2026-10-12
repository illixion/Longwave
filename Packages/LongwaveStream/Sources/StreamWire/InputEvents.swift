// Input events on reliable channel 1 (section 4.3). Each is one message
// (`MessageFraming`); client -> host events start with the client's estimate
// of host time when the input happened (section 5).

/// Modifier bitmask, the same bits as v2's `MacNativeKeyModifiers`.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)

    public static let defined: KeyModifiers = [.shift, .control, .option, .command, .capsLock, .function]
}

/// A key press or release. `keyCode` is in the host's announced key code
/// space (`macVirtual` or `hidUsage`, as v2).
public struct KeyEvent: Sendable, Hashable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Raw values 0-2 are v2's `MouseButton`.
public enum MouseButton: UInt8, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case middle = 2
    case back = 3
    case forward = 4
}

/// A button press or release, with the pointer position in the stream's pixel
/// space, so the click lands where it was made even if a pointer STATE
/// snapshot was lost.
public struct MouseButtonEvent: Sendable, Hashable {
    public var streamID: UInt32
    public var button: MouseButton
    public var x: UInt16
    public var y: UInt16

    public init(streamID: UInt32, button: MouseButton, x: UInt16, y: UInt16) {
        self.streamID = streamID
        self.button = button
        self.x = x
        self.y = y
    }
}

/// A scroll, as v2 (line deltas) plus a high-resolution delta in 1/120 of a
/// notch (the Windows WHEEL_DELTA unit), for trackpads and free-spinning wheels.
public struct ScrollEvent: Sendable, Hashable {
    public var streamID: UInt32
    public var x: UInt16
    public var y: UInt16
    public var lineDeltaX: Int16
    public var lineDeltaY: Int16
    public var preciseDeltaX: Int32
    public var preciseDeltaY: Int32

    public init(streamID: UInt32, x: UInt16, y: UInt16, lineDeltaX: Int16, lineDeltaY: Int16,
                preciseDeltaX: Int32, preciseDeltaY: Int32) {
        self.streamID = streamID
        self.x = x
        self.y = y
        self.lineDeltaX = lineDeltaX
        self.lineDeltaY = lineDeltaY
        self.preciseDeltaX = preciseDeltaX
        self.preciseDeltaY = preciseDeltaY
    }
}

/// Which pad a virtual gamepad presents as. Open: a host that can't present a
/// kind uses its closest.
public struct GamepadKind: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let generic = GamepadKind(rawValue: 0)
    public static let xbox = GamepadKind(rawValue: 1)
    public static let dualSense = GamepadKind(rawValue: 2)
    public static let dualShock4 = GamepadKind(rawValue: 3)
    public static let switchPro = GamepadKind(rawValue: 4)
}

public struct GamepadFeatures: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let motion = GamepadFeatures(rawValue: 1 << 0)
    public static let touchpad = GamepadFeatures(rawValue: 1 << 1)
    public static let rumble = GamepadFeatures(rawValue: 1 << 2)
    public static let triggerRumble = GamepadFeatures(rawValue: 1 << 3)
    public static let lightBar = GamepadFeatures(rawValue: 1 << 4)
    public static let adaptiveTriggers = GamepadFeatures(rawValue: 1 << 5)

    public static let defined: GamepadFeatures = [.motion, .touchpad, .rumble, .triggerRumble, .lightBar, .adaptiveTriggers]
}

public struct GamepadInfo: Sendable, Hashable {
    /// Pads are numbered 0...15 per session; STATE snapshots use the index as
    /// their source.
    public static let maxIndex: UInt8 = 15

    public var index: UInt8
    public var kind: GamepadKind
    public var features: GamepadFeatures

    public init(index: UInt8, kind: GamepadKind, features: GamepadFeatures) {
        self.index = index
        self.kind = kind
        self.features = features
    }
}

/// A client -> host input event.
public enum InputEvent: Sendable, Hashable {
    case keyDown(KeyEvent)
    case keyUp(KeyEvent)
    case mouseDown(MouseButtonEvent)
    case mouseUp(MouseButtonEvent)
    case scroll(ScrollEvent)
    /// Committed text, UTF-8, 1...`maxTextBytes` bytes.
    case textInput(String)
    case focusWindow(streamID: UInt32)
    case gamepadConnected(GamepadInfo)
    case gamepadDisconnected(index: UInt8)
    /// Release every key, button and pad input held (focus loss, reconnect).
    case releaseAll

    public static let maxTextBytes = 4096

    public var messageType: MessageType {
        switch self {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .mouseDown: .mouseDown
        case .mouseUp: .mouseUp
        case .scroll: .scroll
        case .textInput: .textInput
        case .focusWindow: .focusWindow
        case .gamepadConnected: .gamepadConnected
        case .gamepadDisconnected: .gamepadDisconnected
        case .releaseAll: .releaseAll
        }
    }
}

/// An input event with the client's estimate of host time (host monotonic
/// ns) when it happened.
///
/// Body layout: `hostTime u64` then, per type:
///
/// ```
/// keyDown/keyUp       keyCode u16, modifiers u32                      (6)
/// mouseDown/mouseUp   streamID u32, button u8, x u16, y u16          (9)
/// scroll              streamID u32, x u16, y u16, lineDeltaX i16,
///                     lineDeltaY i16, preciseDeltaX i32, preciseDeltaY i32 (20)
/// textInput           UTF-8 bytes (the rest of the body)
/// focusWindow         streamID u32                                    (4)
/// gamepadConnected    index u8, kind u8, features u8                  (3)
/// gamepadDisconnected index u8                                        (1)
/// releaseAll          (nothing)
/// ```
public struct TimedInputEvent: Sendable, Hashable {
    public var hostTime: UInt64
    public var event: InputEvent

    public init(hostTime: UInt64, event: InputEvent) {
        self.hostTime = hostTime
        self.event = event
    }

    public func validate() throws(WireError) {
        switch event {
        case .keyDown(let key), .keyUp(let key):
            guard key.modifiers.isSubset(of: .defined) else { throw .invalid("input.key.modifiers") }
        case .textInput(let text):
            guard !text.isEmpty else { throw .invalid("input.text") }
            guard text.utf8.count <= InputEvent.maxTextBytes else { throw .tooLarge("input.text") }
        case .gamepadConnected(let info):
            guard info.index <= GamepadInfo.maxIndex else { throw .invalid("input.gamepad.index") }
            guard info.features.isSubset(of: .defined) else { throw .invalid("input.gamepad.features") }
        case .gamepadDisconnected(let index):
            guard index <= GamepadInfo.maxIndex else { throw .invalid("input.gamepad.index") }
        case .mouseDown, .mouseUp, .scroll, .focusWindow, .releaseAll:
            break
        }
    }

    public func encodeBody(to writer: inout WireWriter) throws(WireError) {
        try validate()
        writer.writeUInt64(hostTime)
        switch event {
        case .keyDown(let key), .keyUp(let key):
            writer.writeUInt16(key.keyCode)
            writer.writeUInt32(key.modifiers.rawValue)
        case .mouseDown(let button), .mouseUp(let button):
            writer.writeUInt32(button.streamID)
            writer.writeUInt8(button.button.rawValue)
            writer.writeUInt16(button.x)
            writer.writeUInt16(button.y)
        case .scroll(let scroll):
            writer.writeUInt32(scroll.streamID)
            writer.writeUInt16(scroll.x)
            writer.writeUInt16(scroll.y)
            writer.writeInt16(scroll.lineDeltaX)
            writer.writeInt16(scroll.lineDeltaY)
            writer.writeInt32(scroll.preciseDeltaX)
            writer.writeInt32(scroll.preciseDeltaY)
        case .textInput(let text):
            writer.writeBytes(text.utf8)
        case .focusWindow(let streamID):
            writer.writeUInt32(streamID)
        case .gamepadConnected(let info):
            writer.writeUInt8(info.index)
            writer.writeUInt8(info.kind.rawValue)
            writer.writeUInt8(info.features.rawValue)
        case .gamepadDisconnected(let index):
            writer.writeUInt8(index)
        case .releaseAll:
            break
        }
    }

    /// The complete message (`type | length | body`).
    public func encodedMessage() throws(WireError) -> [UInt8] {
        var body = WireWriter(reservingCapacity: 32)
        try encodeBody(to: &body)
        return try MessageFraming.encode(event.messageType, body: body.bytes)
    }

    /// Decodes an input message; nil if its type is not an input event (the
    /// caller skips it). The body must be exactly the defined layout.
    /// The message types `TimedInputEvent` decodes.
    public static let messageTypes: Set<MessageType> = [
        .keyDown, .keyUp, .mouseDown, .mouseUp, .scroll, .textInput, .focusWindow,
        .gamepadConnected, .gamepadDisconnected, .releaseAll,
    ]

    /// Decodes an input message; nil if its type is not an input event (the
    /// caller skips it). The body must be exactly the defined layout.
    public init?(message: Message) throws(WireError) {
        guard Self.messageTypes.contains(message.type) else { return nil }
        var reader = WireReader(message.body)
        hostTime = try reader.readUInt64()
        switch message.type {
        case .keyDown, .keyUp:
            let key = KeyEvent(keyCode: try reader.readUInt16(), modifiers: KeyModifiers(rawValue: try reader.readUInt32()))
            event = message.type == .keyDown ? .keyDown(key) : .keyUp(key)
        case .mouseDown, .mouseUp:
            let streamID = try reader.readUInt32()
            guard let button = MouseButton(rawValue: try reader.readUInt8()) else { throw .invalid("input.mouse.button") }
            let value = MouseButtonEvent(streamID: streamID, button: button, x: try reader.readUInt16(), y: try reader.readUInt16())
            event = message.type == .mouseDown ? .mouseDown(value) : .mouseUp(value)
        case .scroll:
            event = .scroll(ScrollEvent(streamID: try reader.readUInt32(), x: try reader.readUInt16(), y: try reader.readUInt16(),
                                        lineDeltaX: try reader.readInt16(), lineDeltaY: try reader.readInt16(),
                                        preciseDeltaX: try reader.readInt32(), preciseDeltaY: try reader.readInt32()))
        case .textInput:
            let bytes = try reader.readBytes(reader.remaining)
            guard bytes.count <= InputEvent.maxTextBytes else { throw .tooLarge("input.text") }
            event = .textInput(try Self.validUTF8(bytes))
        case .focusWindow:
            event = .focusWindow(streamID: try reader.readUInt32())
        case .gamepadConnected:
            event = .gamepadConnected(GamepadInfo(index: try reader.readUInt8(), kind: GamepadKind(rawValue: try reader.readUInt8()),
                                                  features: GamepadFeatures(rawValue: try reader.readUInt8())))
        case .gamepadDisconnected:
            event = .gamepadDisconnected(index: try reader.readUInt8())
        default: // .releaseAll; `messageTypes` admits nothing else
            event = .releaseAll
        }
        try reader.finish()
        try validate()
    }

    /// Foundation-free strict UTF-8 check: decoding replaces ill-formed
    /// sequences with U+FFFD, so the text is valid exactly when re-encoding
    /// reproduces the input.
    static func validUTF8(_ bytes: ArraySlice<UInt8>) throws(WireError) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw .invalid("input.text.utf8") }
        return text
    }
}

// MARK: - Host -> client

/// Whether the host will act on mouse or keyboard-shortcut input (v2's
/// `RemoteControlStatus`).
public enum RemoteControlStatus: UInt8, Sendable, CaseIterable {
    case available = 0
    case disabled = 1
    case accessibilityDenied = 2
}

public enum ControlStatusKind: UInt8, Sendable, CaseIterable {
    case mouse = 0
    case keyboard = 1
}

/// Rumble amplitudes, 0...65535. The client stops after `durationMs` unless
/// the host sends again, so a lost session can't leave a pad buzzing; 0 stops.
public struct Rumble: Sendable, Hashable {
    public var gamepad: UInt8
    public var lowFrequency: UInt16
    public var highFrequency: UInt16
    public var leftTrigger: UInt16
    public var rightTrigger: UInt16
    public var durationMs: UInt16

    public init(gamepad: UInt8, lowFrequency: UInt16, highFrequency: UInt16, leftTrigger: UInt16 = 0,
                rightTrigger: UInt16 = 0, durationMs: UInt16) {
        self.gamepad = gamepad
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.durationMs = durationMs
    }
}

public enum TriggerSide: UInt8, Sendable, CaseIterable {
    case left = 0
    case right = 1
}

/// Cursor shape hints, open: unknown shapes draw as the arrow.
public struct CursorShape: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let arrow = CursorShape(rawValue: 0)
    public static let iBeam = CursorShape(rawValue: 1)
    public static let pointingHand = CursorShape(rawValue: 2)
    public static let crosshair = CursorShape(rawValue: 3)
    public static let resizeLeftRight = CursorShape(rawValue: 4)
    public static let resizeUpDown = CursorShape(rawValue: 5)
    public static let notAllowed = CursorShape(rawValue: 6)
}

/// A host -> client input feedback event. Bodies:
///
/// ```
/// rumble         gamepad u8, low u16, high u16, leftTrigger u16, rightTrigger u16, durationMs u16 (11)
/// lightBar       gamepad u8, red u8, green u8, blue u8                                  (4)
/// triggerEffect  gamepad u8, side u8, effect bytes (0...32; empty = off; DualSense format)
/// cursor         visible u8 (0/1), shape u8                                             (2)
/// controlStatus  kind u8, status u8                                                     (2)
/// ```
public enum HostInputEvent: Sendable, Hashable {
    case rumble(Rumble)
    case lightBar(gamepad: UInt8, red: UInt8, green: UInt8, blue: UInt8)
    case triggerEffect(gamepad: UInt8, side: TriggerSide, effect: [UInt8])
    case cursor(visible: Bool, shape: CursorShape)
    case controlStatus(ControlStatusKind, RemoteControlStatus)

    public static let maxTriggerEffectBytes = 32

    public var messageType: MessageType {
        switch self {
        case .rumble: .rumble
        case .lightBar: .lightBar
        case .triggerEffect: .triggerEffect
        case .cursor: .cursor
        case .controlStatus: .controlStatus
        }
    }

    public func validate() throws(WireError) {
        switch self {
        case .rumble(let rumble):
            guard rumble.gamepad <= GamepadInfo.maxIndex else { throw .invalid("hostInput.gamepad") }
        case .lightBar(let gamepad, _, _, _):
            guard gamepad <= GamepadInfo.maxIndex else { throw .invalid("hostInput.gamepad") }
        case .triggerEffect(let gamepad, _, let effect):
            guard gamepad <= GamepadInfo.maxIndex else { throw .invalid("hostInput.gamepad") }
            guard effect.count <= Self.maxTriggerEffectBytes else { throw .tooLarge("hostInput.triggerEffect") }
        case .cursor, .controlStatus:
            break
        }
    }

    public func encodeBody(to writer: inout WireWriter) throws(WireError) {
        try validate()
        switch self {
        case .rumble(let r):
            writer.writeUInt8(r.gamepad)
            writer.writeUInt16(r.lowFrequency)
            writer.writeUInt16(r.highFrequency)
            writer.writeUInt16(r.leftTrigger)
            writer.writeUInt16(r.rightTrigger)
            writer.writeUInt16(r.durationMs)
        case .lightBar(let gamepad, let red, let green, let blue):
            writer.writeBytes([gamepad, red, green, blue])
        case .triggerEffect(let gamepad, let side, let effect):
            writer.writeUInt8(gamepad)
            writer.writeUInt8(side.rawValue)
            writer.writeBytes(effect)
        case .cursor(let visible, let shape):
            writer.writeBool(visible)
            writer.writeUInt8(shape.rawValue)
        case .controlStatus(let kind, let status):
            writer.writeUInt8(kind.rawValue)
            writer.writeUInt8(status.rawValue)
        }
    }

    public func encodedMessage() throws(WireError) -> [UInt8] {
        var body = WireWriter(reservingCapacity: 16)
        try encodeBody(to: &body)
        return try MessageFraming.encode(messageType, body: body.bytes)
    }

    /// Nil if the message is not a host input event.
    public init?(message: Message) throws(WireError) {
        var reader = WireReader(message.body)
        switch message.type {
        case .rumble:
            self = .rumble(Rumble(gamepad: try reader.readUInt8(), lowFrequency: try reader.readUInt16(),
                                  highFrequency: try reader.readUInt16(), leftTrigger: try reader.readUInt16(),
                                  rightTrigger: try reader.readUInt16(), durationMs: try reader.readUInt16()))
        case .lightBar:
            self = .lightBar(gamepad: try reader.readUInt8(), red: try reader.readUInt8(),
                             green: try reader.readUInt8(), blue: try reader.readUInt8())
        case .triggerEffect:
            let gamepad = try reader.readUInt8()
            guard let side = TriggerSide(rawValue: try reader.readUInt8()) else { throw .invalid("hostInput.trigger") }
            let effect = try reader.readBytes(reader.remaining)
            guard effect.count <= Self.maxTriggerEffectBytes else { throw .tooLarge("hostInput.triggerEffect") }
            self = .triggerEffect(gamepad: gamepad, side: side, effect: Array(effect))
        case .cursor:
            self = .cursor(visible: try reader.readBool("hostInput.cursor.visible"), shape: CursorShape(rawValue: try reader.readUInt8()))
        case .controlStatus:
            guard let kind = ControlStatusKind(rawValue: try reader.readUInt8()) else { throw .invalid("hostInput.status.kind") }
            guard let status = RemoteControlStatus(rawValue: try reader.readUInt8()) else { throw .invalid("hostInput.status") }
            self = .controlStatus(kind, status)
        default:
            return nil
        }
        try reader.finish()
        try validate()
    }
}
