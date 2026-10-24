import CoreMedia
import DebugTrace
import Foundation
import Network
import StreamCrypto
import StreamHost
import StreamTransport
import StreamWire

/// The desktop stream over Native v3 (NATIVE_V3_PROTOCOL.md), on UDP 4857
/// beside v2's TCP 4857. It is the Network.framework half of the package's
/// sans-I/O `HostEndpoint`: it owns the socket and the timer, and each viewer
/// gets its own `VideoStreamSender` on the one shared capture and encode.
///
/// The first cut carries the desktop, remote input, the display choice and the
/// remote-control status. Window streams, stills and audio stay on v2. The
/// callbacks mirror `MacNativeStreamServer`'s, so the streaming controller
/// treats both servers' viewers as one set.
nonisolated final class MacNativeV3Server: @unchecked Sendable {
    nonisolated(unsafe) var onDeviceIdentified: (@Sendable (String?) -> Void)?
    nonisolated(unsafe) var onClientConnected: (@Sendable (_ deviceName: String, _ wantsScreen: Bool) -> Void)?
    nonisolated(unsafe) var onClientsChanged: (@Sendable (_ clients: [MacNativeStreamServer.ClientSummary]) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onMouseMove: (@Sendable (UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onMouseDown: (@Sendable (MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onMouseUp: (@Sendable (MacNativeStreamProtocol.MouseButton, UInt16, UInt16) -> Void)?
    nonisolated(unsafe) var onScroll: (@Sendable (UInt16, UInt16, Int16, Int16) -> Void)?
    nonisolated(unsafe) var onKeyDown: (@Sendable (UInt16, MacNativeKeyModifiers) -> Void)?
    nonisolated(unsafe) var onKeyUp: (@Sendable (UInt16, MacNativeKeyModifiers) -> Void)?
    nonisolated(unsafe) var onReleaseAll: (@Sendable () -> Void)?
    /// The desktop stream gained its first v3 viewer, or lost its last.
    nonisolated(unsafe) var onDesktopStreamStart: (@Sendable () -> Void)?
    nonisolated(unsafe) var onDesktopStreamStop: (@Sendable () -> Void)?
    nonisolated(unsafe) var onKeyFrameNeeded: (@Sendable () -> Void)?
    nonisolated(unsafe) var onSelectDisplay: (@Sendable (String) -> Void)?
    nonisolated(unsafe) var onConfigureVirtualDisplay: (@Sendable (MacNativeStreamProtocol.VirtualDisplayChange) -> Void)?
    /// The gate reopened (`desktopCanAcceptFrame`).
    nonisolated(unsafe) var onDesktopPipeClear: (@Sendable () -> Void)?
    /// The slowest viewer's encoder bitrate in bits/s, or nil with no viewers.
    nonisolated(unsafe) var onTargetBitrate: (@Sendable (Int?) -> Void)?
    /// The slowest viewer's smoothed round trip, ms.
    nonisolated(unsafe) var onLinkLatency: (@Sendable (Double) -> Void)?

    private struct PeerKey: Hashable, Sendable {
        let id: ObjectIdentifier
    }

    private final class Peer {
        let connection: NWConnection
        var lastReceive: UInt64

        init(connection: NWConnection, now: UInt64) {
            self.connection = connection
            lastReceive = now
        }
    }

    private final class Viewer {
        let index: UInt32
        let deviceID: String
        let deviceName: String
        let grants: Set<CompanionGrant>
        let capabilities: CapabilitySet
        /// The hello's screen intent, then the client's `streamStart`/`streamStop`
        /// for the desktop (its Screen toggle).
        var wantsScreen: Bool
        var confirmed = false
        var sender: VideoStreamSender
        var lastPointer: UInt32?

        init(index: UInt32, deviceID: String, hello: ClientHello, grants: Set<CompanionGrant>, capabilities: CapabilitySet) {
            self.index = index
            self.deviceID = deviceID
            deviceName = hello.deviceName ?? "Longwave"
            self.grants = grants
            self.capabilities = capabilities
            wantsScreen = hello.intent.contains(.screen) && grants.contains(.screen)
            sender = VideoStreamSender(configuration: .init(streamID: NativeV3.desktopStreamID))
        }

        var wantsDesktop: Bool { confirmed && wantsScreen }

        var summary: MacNativeStreamServer.ClientSummary {
            .init(deviceName: deviceName, protocolVersion: 3, decodesHEVC422: capabilities.contains(.hevc422))
        }
    }

    /// What this host offers. HEVC is the baseline and needs no capability.
    private static let capabilities = CapabilitySet([.nack, .hevc422])
    /// IDRs for one stream at most this often (§6.3).
    private static let keyFrameInterval: UInt64 = 250_000_000

    private let port: UInt16
    private let keyring: CompanionKeyring
    private let queue = DispatchQueue(label: "pro.longwave.companion.native-v3", qos: .userInteractive)
    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "MacNativeV3Server")
    private let portListener: CompanionPortListener
    private nonisolated(unsafe) var timer: NativeV3Timer?

    private nonisolated(unsafe) var endpoint = HostEndpoint<PeerKey>(devices: [])
    private nonisolated(unsafe) var peers: [PeerKey: Peer] = [:]
    private nonisolated(unsafe) var viewers: [UInt32: Viewer] = [:]
    /// Hellos answered inside `endpoint.receive`, picked up by its `.connected`.
    private nonisolated(unsafe) var answered: [String: (hello: ClientHello, grants: Set<CompanionGrant>, capabilities: CapabilitySet)] = [:]
    /// The desktop format with `firstFrameNumber` left for each viewer to fill.
    private nonisolated(unsafe) var currentFormat: FormatDescription?
    private nonisolated(unsafe) var currentDisplayList: [UInt8]?
    private nonisolated(unsafe) var mouseAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var keyboardAvailability = MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
    private nonisolated(unsafe) var lastKeyFrameRequest: UInt64?
    private nonisolated(unsafe) var lastBitrate: Int?
    private nonisolated(unsafe) var lastLinkReport: UInt64 = 0
    private nonisolated(unsafe) var lastStatsLog: UInt64 = 0
    /// The encoder's most (bits/s), which each viewer's rate estimate stops at.
    private nonisolated(unsafe) var encoderCeiling: Int?
    private nonisolated(unsafe) var lastSweep: UInt64 = 0
    private nonisolated(unsafe) var desktopRunning = false

    private let gateLock = NSLock()
    private nonisolated(unsafe) var gateOpen = true
    private nonisolated(unsafe) var hasDesktopViewers = false

    nonisolated init(port: UInt16, keyring: CompanionKeyring) {
        self.port = port
        self.keyring = keyring
        portListener = CompanionPortListener(name: "Native v3", queue: queue, log: log)
    }

    // MARK: Lifecycle

    nonisolated func start() {
        queue.async { [self] in
            endpoint = HostEndpoint(devices: devices())
            timer = NativeV3Timer(queue: queue) { [weak self] in
                self?.timer?.fired()
                self?.pump()
            }
            portListener.onUnavailable = { [weak self] message in self?.onError?(message) }
            portListener.start { [weak self] in
                guard let self else { throw CancellationError() }
                let listener = try NWListener(using: NativeV3.parameters(), on: NWEndpoint.Port(rawValue: port)!)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                return listener
            }
        }
    }

    nonisolated func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            for viewer in Array(viewers.values) { endSession(viewer, reason: "The Mac stopped streaming.") }
            flush(now: NativeV3.now())
            portListener.stop(completion: completion)
            for peer in peers.values { peer.connection.cancel() }
            peers = [:]
            viewers = [:]
            currentFormat = nil
            currentDisplayList = nil
            timer?.cancel()
            timer = nil
        }
    }

    /// Paired devices changed: removed devices' sessions end, and a viewer
    /// whose grants changed is told to connect again.
    nonisolated func reloadCredentials() {
        queue.async { [self] in
            for index in endpoint.setDevices(devices()) {
                if let viewer = viewers[index] { removeViewer(viewer, reason: "device removed") }
            }
            for viewer in Array(viewers.values) where keyring.entry(deviceID: viewer.deviceID)?.grants != viewer.grants {
                endSession(viewer, reason: "This device's access to this Mac changed. Connect again.")
            }
            pump()
        }
    }

    private func devices() -> [HostEndpoint<PeerKey>.Device] {
        keyring.credentials.compactMap { credential in
            guard let psk = NativeV3.psk(for: credential), let deviceID = credential.deviceID else { return nil }
            return .init(psk: psk, deviceID: deviceID)
        }
    }

    // MARK: Published state

    nonisolated func setEncoderCeiling(_ bitsPerSecond: Int) {
        queue.async { [self] in
            guard bitsPerSecond != encoderCeiling else { return }
            encoderCeiling = bitsPerSecond
            for viewer in viewers.values { applyEncoderCeiling(to: viewer) }
            pump()
        }
    }

    private func applyEncoderCeiling(to viewer: Viewer) {
        guard let udpPayload = endpoint.sessions[viewer.index]?.session.udpPayload else { return }
        viewer.sender.setEncoderCeiling(encoderCeiling, udpPayload: udpPayload)
    }

    nonisolated func setMouseAvailability(_ status: UInt8) {
        queue.async { [self] in
            mouseAvailability = status
            for viewer in viewers.values where viewer.confirmed { sendControlStatus(.mouse, status, to: viewer) }
            pump()
        }
    }

    nonisolated func setKeyboardAvailability(_ status: UInt8) {
        queue.async { [self] in
            keyboardAvailability = status
            for viewer in viewers.values where viewer.confirmed { sendControlStatus(.keyboard, status, to: viewer) }
            pump()
        }
    }

    nonisolated func broadcastDisplayList(_ list: MacNativeStreamProtocol.DisplayList) {
        guard let json = try? JSONEncoder().encode(list) else { return }
        queue.async { [self] in
            currentDisplayList = Array(json)
            for viewer in viewers.values where viewer.confirmed && viewer.grants.contains(.screen) {
                send(.displayList, body: Array(json), to: viewer)
            }
            pump()
        }
    }

    /// The desktop capture failed: its viewers have nothing left to watch.
    nonisolated func disconnectDesktopViewers(withError message: String) {
        queue.async { [self] in
            for viewer in Array(viewers.values) where viewer.wantsDesktop { endSession(viewer, reason: message) }
            pump()
        }
    }

    /// Whether a v3 viewer takes the desktop stream. Read from the capture's queue.
    nonisolated func hasVideoViewers() -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return hasDesktopViewers
    }

    /// Whether every v3 desktop viewer can take another frame now. Read from
    /// the capture's queue.
    nonisolated func desktopCanAcceptFrame() -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        return gateOpen
    }

    // MARK: Media

    nonisolated func broadcastFormatDescription(_ data: Data) {
        guard let format = Self.formatDescription(from: data) else {
            log.error("Could not describe the desktop format for v3 viewers")
            return
        }
        queue.async { [self] in
            currentFormat = format
            for viewer in viewers.values where viewer.wantsDesktop { sendFormat(to: viewer) }
            pump()
        }
    }

    nonisolated func broadcastFrame(_ data: Data, isKeyFrame: Bool, timestampNanoseconds: UInt64) {
        queue.async { [self] in
            let now = NativeV3.now()
            var wantsKeyFrame = false
            for viewer in viewers.values where viewer.wantsDesktop {
                guard let udpPayload = endpoint.sessions[viewer.index]?.session.udpPayload else { continue }
                do {
                    switch try viewer.sender.submit(accessUnit: data, isKeyFrame: isKeyFrame,
                                                    captureTime: timestampNanoseconds, udpPayload: udpPayload, now: now) {
                    case .queued:
                        break
                    case .awaitingKeyFrame, .queueFull:
                        wantsKeyFrame = true
                    }
                } catch {
                    log.error("Could not shard a desktop frame: \(String(describing: error), privacy: .public)")
                }
            }
            if wantsKeyFrame { requestKeyFrame(now: now) }
            pump()
        }
    }

    private func sendFormat(to viewer: Viewer) {
        guard var format = currentFormat else { return }
        format.firstFrameNumber = viewer.sender.upcomingFrameNumber
        // Frames from the old format would decode against the new one.
        viewer.sender.recoveryRequested()
        guard let body = try? format.encoded() else { return }
        send(.formatDescription, body: body, to: viewer)
    }

    private func requestKeyFrame(now: UInt64) {
        if let last = lastKeyFrameRequest, now - last < Self.keyFrameInterval { return }
        lastKeyFrameRequest = now
        onKeyFrameNeeded?()
    }

    /// The v3 format for a CoreMedia ImageDescription blob: the blob travels as
    /// is (Apple clients rebuild the description from it); size, chroma and bit
    /// depth are read out for clients that don't.
    private static func formatDescription(from data: Data) -> FormatDescription? {
        var description: CMVideoFormatDescription?
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMVideoFormatDescriptionCreateFromBigEndianImageDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianImageDescriptionData: base, size: data.count,
                stringEncoding: CFStringGetSystemEncoding(), flavor: nil,
                formatDescriptionOut: &description)
        }
        guard status == noErr, let description else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let codec: VideoCodec
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_H264: codec = .h264
        case kCMVideoCodecType_AV1: codec = .av1
        default: codec = .hevc
        }
        // hvcC: chroma_format_idc at byte 16, bit_depth_luma_minus8 at byte 17.
        var chroma = ChromaFormat.yuv420
        var bitDepth: UInt8 = 8
        if let atoms = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let hvcC = atoms["hvcC"] as? Data, hvcC.count > 17 {
            chroma = ChromaFormat(rawValue: hvcC[hvcC.startIndex + 16] & 0x03) ?? .yuv420
            bitDepth = (hvcC[hvcC.startIndex + 17] & 0x07) + 8
        }
        let format = FormatDescription(
            streamID: NativeV3.desktopStreamID, firstFrameNumber: 0, codec: codec, formatKind: .coreMediaImageDescription,
            size: PixelSize(width: UInt16(clamping: dimensions.width), height: UInt16(clamping: dimensions.height)),
            bitDepth: bitDepth, chromaFormat: chroma, colour: colour(of: description), configuration: Array(data))
        return (try? format.validate()) != nil ? format : nil
    }

    private static func colour(of description: CMFormatDescription) -> ColourInfo {
        func value(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
        }
        var colour = ColourInfo.bt709
        switch value(kCMFormatDescriptionExtension_ColorPrimaries) {
        case String(kCMFormatDescriptionColorPrimaries_P3_D65): colour.primaries = 12
        case String(kCMFormatDescriptionColorPrimaries_ITU_R_2020): colour.primaries = 9
        default: break
        }
        switch value(kCMFormatDescriptionExtension_TransferFunction) {
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ): colour.transfer = 16
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG): colour.transfer = 18
        case String(kCMFormatDescriptionTransferFunction_sRGB): colour.transfer = 13
        default: break
        }
        if value(kCMFormatDescriptionExtension_YCbCrMatrix) == String(kCMFormatDescriptionYCbCrMatrix_ITU_R_2020) {
            colour.matrix = 9
        }
        colour.fullRange = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool ?? false
        return colour
    }

    // MARK: Datagrams

    private func accept(_ connection: NWConnection) {
        let key = PeerKey(id: ObjectIdentifier(connection))
        peers[key] = Peer(connection: connection, now: NativeV3.now())
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.peers[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, key: key)
    }

    private func receive(on connection: NWConnection, key: PeerKey) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { handle([UInt8](data), from: key) }
            if error == nil, peers[key] != nil { receive(on: connection, key: key) }
        }
    }

    private func handle(_ datagram: [UInt8], from key: PeerKey) {
        let now = NativeV3.now()
        peers[key]?.lastReceive = now
        let events = endpoint.receive(datagram, from: key, now: now) { deviceID, hello in
            answer(deviceID: deviceID, hello: hello)
        }
        for event in events { handle(event, now: now) }
        pump()
    }

    /// The hello-ack for a paired device. A device without grants gets one
    /// too (`refused`), so it can say why instead of timing out.
    private func answer(deviceID: String, hello bytes: [UInt8]) -> [UInt8]? {
        guard let hello = try? ClientHello(decoding: bytes) else { return nil }
        let grants = keyring.entry(deviceID: deviceID)?.grants ?? []
        let ack = HostHelloAck(
            answering: hello, hostCapabilities: Self.capabilities, platform: .macOS, keyCodeSpace: .macVirtual,
            grants: SessionGrants(grants), maxUDPPayload: DatagramLayout.maxProbedUDPPayload,
            hostName: NativeV3.helloName(Host.current().localizedName ?? "Mac"), software: NativeV3.softwareVersion)
        answered[deviceID] = (hello, grants, hello.sessionCapabilities(from: ack))
        return try? ack.encoded()
    }

    private func handle(_ event: HostEndpoint<PeerKey>.Event, now: UInt64) {
        switch event {
        case .send(let bytes, let key):
            if let connection = peers[key]?.connection { NativeV3.send([bytes], on: connection) }
        case .connected(let index, let deviceID, _):
            guard let (hello, grants, capabilities) = answered.removeValue(forKey: deviceID) else { return }
            guard !grants.isEmpty else {
                endpoint.remove(index)
                return
            }
            let viewer = Viewer(index: index, deviceID: deviceID, hello: hello, grants: grants, capabilities: capabilities)
            viewers[index] = viewer
            _ = endpoint.withSession(index) { $0.setPathCeiling(DatagramLayout.maxProbedUDPPayload, now: now) }
            applyEncoderCeiling(to: viewer)
        case .confirmed(let index):
            if let viewer = viewers[index] { confirm(viewer) }
        case .events(let index, let events):
            if let viewer = viewers[index] { handle(events, from: viewer, now: now) }
        case .superseded(let index, _):
            if let viewer = viewers[index] { removeViewer(viewer, reason: "superseded by a newer session") }
        case .closed(let index, let closure):
            if let viewer = viewers[index] { removeViewer(viewer, reason: "session closed: \(closure)") }
        }
    }

    private func confirm(_ viewer: Viewer) {
        guard !viewer.confirmed else { return }
        let desktopWasRunning = viewers.values.contains(where: \.wantsDesktop)
        viewer.confirmed = true
        log.notice("v3 viewer \(viewer.deviceName, privacy: .private(mask: .hash)) connected")
        onDeviceIdentified?(viewer.deviceID)
        sendControlStatus(.mouse, mouseAvailability, to: viewer)
        sendControlStatus(.keyboard, keyboardAvailability, to: viewer)
        if viewer.grants.contains(.screen), let currentDisplayList { send(.displayList, body: currentDisplayList, to: viewer) }
        // Before the stream starts: the capture reads the viewers' chroma.
        onClientConnected?(viewer.deviceName, viewer.wantsScreen)
        onClientsChanged?(summaries)
        if viewer.wantsScreen { startDesktop(for: viewer, alreadyRunning: desktopWasRunning) }
    }

    /// A viewer joins the desktop stream: the capture starts if it is the first,
    /// otherwise it gets the current format and the next frame is a key frame.
    private func startDesktop(for viewer: Viewer, alreadyRunning: Bool) {
        log.notice("v3 desktop subscribed (\(alreadyRunning ? "joining the running stream" : "starting the capture", privacy: .public))")
        if alreadyRunning {
            sendFormat(to: viewer)
            lastKeyFrameRequest = nil
            requestKeyFrame(now: NativeV3.now())
        } else {
            desktopRunning = true
            // Before the capture starts: it reads `hasVideoViewers` to decide
            // whether it is for a watch alone.
            updateGate()
            onDesktopStreamStart?()
        }
    }

    private func stopDesktopIfUnwatched() {
        guard desktopRunning, !viewers.values.contains(where: \.wantsDesktop) else { return }
        log.notice("v3 desktop unsubscribed by its last viewer")
        desktopRunning = false
        updateGate()
        onDesktopStreamStop?()
    }

    private var summaries: [MacNativeStreamServer.ClientSummary] {
        viewers.values.filter(\.confirmed).sorted { $0.index < $1.index }.map(\.summary)
    }

    private func handle(_ events: [SessionEvent], from viewer: Viewer, now: UInt64) {
        for event in events {
            switch event {
            case .message(.input, let message):
                guard viewer.grants.contains(.input), let input = try? TimedInputEvent(message: message) else { continue }
                handle(input.event)
            case .message(.control, let message):
                handle(message, from: viewer, now: now)
            case .message:
                continue
            case .state(let snapshot):
                guard viewer.grants.contains(.input), case .pointerAbsolute(let pointer) = snapshot.payload else { continue }
                if let last = viewer.lastPointer, !SerialNumber.isNewer(snapshot.sequence, than: last) { continue }
                viewer.lastPointer = snapshot.sequence
                onMouseMove?(pointer.x, pointer.y)
            case .nack(let nack):
                viewer.sender.handle(nack)
            case .feedback(_, let results):
                let rtt = endpoint.sessions[viewer.index]?.session.rtt.smoothed ?? 2_000_000
                viewer.sender.onFeedback(results, now: now, rtt: rtt)
            case .video, .audio:
                continue
            }
        }
    }

    private func handle(_ input: InputEvent) {
        switch input {
        case .keyDown(let key):
            onKeyDown?(key.keyCode, MacNativeKeyModifiers(rawValue: key.modifiers.rawValue))
        case .keyUp(let key):
            onKeyUp?(key.keyCode, MacNativeKeyModifiers(rawValue: key.modifiers.rawValue))
        case .mouseDown(let event):
            onMouseDown?(Self.button(event.button), event.x, event.y)
        case .mouseUp(let event):
            onMouseUp?(Self.button(event.button), event.x, event.y)
        case .scroll(let scroll):
            onScroll?(scroll.x, scroll.y, scroll.lineDeltaX, scroll.lineDeltaY)
        case .releaseAll:
            onReleaseAll?()
        case .textInput, .focusWindow, .gamepadConnected, .gamepadDisconnected:
            break
        }
    }

    private static func button(_ button: MouseButton) -> MacNativeStreamProtocol.MouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle, .back, .forward: .other
        }
    }

    private func handle(_ message: Message, from viewer: Viewer, now: UInt64) {
        switch message.type {
        case .recoveryRequest:
            guard viewer.wantsDesktop, (try? RecoveryRequest(decoding: message.body)) != nil else { return }
            viewer.sender.recoveryRequested()
            requestKeyFrame(now: now)
        case .selectDisplay:
            guard viewer.grants.contains(.screen), let id = try? TextBody.decode(message.body) else { return }
            onSelectDisplay?(id)
        case .virtualDisplayChange:
            guard viewer.grants.contains(.screen), message.body.count <= 1024,
                  let change = try? JSONDecoder().decode(MacNativeStreamProtocol.VirtualDisplayChange.self,
                                                         from: Data(message.body)) else { return }
            onConfigureVirtualDisplay?(change)
        case .streamStart:
            guard viewer.grants.contains(.screen), !viewer.wantsScreen,
                  let subscription = try? StreamSubscription(decoding: message.body),
                  subscription.streamID == NativeV3.desktopStreamID else { return }
            let running = viewers.values.contains(where: \.wantsDesktop)
            viewer.wantsScreen = true
            startDesktop(for: viewer, alreadyRunning: running)
        case .streamStop:
            guard viewer.wantsScreen, let subscription = try? StreamSubscription(decoding: message.body),
                  subscription.streamID == NativeV3.desktopStreamID else { return }
            viewer.wantsScreen = false
            stopDesktopIfUnwatched()
        case .bye:
            endpoint.remove(viewer.index)
            removeViewer(viewer, reason: "viewer said goodbye")
        default:
            break
        }
    }

    // MARK: Sending

    private func send(_ type: MessageType, body: [UInt8], to viewer: Viewer) {
        _ = endpoint.withSession(viewer.index) { try? $0.send(type, body: body, on: .control) }
    }

    private func sendControlStatus(_ kind: ControlStatusKind, _ status: UInt8, to viewer: Viewer) {
        let effective = viewer.grants.contains(.input) ? status : MacNativeStreamProtocol.RemoteControlStatus.disabled.rawValue
        let event = HostInputEvent.controlStatus(kind, RemoteControlStatus(rawValue: effective) ?? .disabled)
        var body = WireWriter(reservingCapacity: 4)
        guard (try? event.encodeBody(to: &body)) != nil else { return }
        _ = endpoint.withSession(viewer.index) { try? $0.send(event.messageType, body: body.bytes, on: .input) }
    }

    /// Ends a viewer's session with a reason it can show.
    private func endSession(_ viewer: Viewer, reason: String) {
        log.notice("Ending a v3 viewer's session: \(reason, privacy: .public)")
        if let body = try? TextBody.encode(reason) {
            _ = endpoint.withSession(viewer.index) { try? $0.send(.bye, body: body, on: .control) }
        }
        flush(now: NativeV3.now())
        endpoint.remove(viewer.index)
        removeViewer(viewer, reason: "ended by the host")
    }

    private func removeViewer(_ viewer: Viewer, reason: String) {
        guard viewers.removeValue(forKey: viewer.index) != nil else { return }
        guard viewer.confirmed else { return }
        log.notice("v3 viewer \(viewer.deviceName, privacy: .private(mask: .hash)) left: \(reason, privacy: .public)")
        onClientsChanged?(summaries)
        stopDesktopIfUnwatched()
        updateGate()
    }

    /// Sends what's due: each viewer's paced media, then every session's small
    /// datagrams. Then re-arms the timer for the earliest next work.
    private func pump() {
        let now = NativeV3.now()
        for viewer in viewers.values where viewer.wantsDesktop {
            guard let address = endpoint.sessions[viewer.index]?.address,
                  let connection = peers[address]?.connection else { continue }
            var datagrams: [[UInt8]] = []
            while let output = viewer.sender.next(now: now) {
                let datagram: [UInt8]?? = endpoint.withSession(viewer.index) { session in
                    switch output {
                    case .shard(let header, let data): try? session.sealVideo(header, data: data, now: now)
                    case .padding(let size, let cluster): try? session.sealPadding(size: size, probeCluster: cluster, now: now)
                    }
                }
                if let datagram = datagram ?? nil { datagrams.append(datagram) }
                if datagrams.count >= 32 {
                    NativeV3.send(datagrams, on: connection)
                    datagrams = []
                }
            }
            NativeV3.send(datagrams, on: connection)
        }
        flush(now: now)
        updateGate()
        report(now: now)
        if now - lastSweep > 5_000_000_000 { sweepPeers(now: now) }

        var wakes: [UInt64] = [now + 1_000_000_000]
        if let next = endpoint.nextWakeTime(now: now) { wakes.append(next) }
        for viewer in viewers.values where viewer.wantsDesktop {
            if let next = viewer.sender.nextWakeTime(now: now) { wakes.append(next) }
        }
        timer?.arm(at: max(wakes.min()!, now + 50_000))
    }

    private func flush(now: UInt64) {
        let (datagrams, closed) = endpoint.poll(now: now)
        var byPeer: [PeerKey: [[UInt8]]] = [:]
        for datagram in datagrams { byPeer[datagram.to, default: []].append(datagram.bytes) }
        for (key, batch) in byPeer {
            if let connection = peers[key]?.connection { NativeV3.send(batch, on: connection) }
        }
        for (index, closure) in closed {
            if let viewer = viewers[index] { removeViewer(viewer, reason: "session closed: \(closure)") }
        }
    }

    private func updateGate() {
        let desktop = viewers.values.filter(\.wantsDesktop)
        let open = desktop.allSatisfy(\.sender.canAcceptFrame)
        gateLock.lock()
        let wasOpen = gateOpen
        gateOpen = open
        hasDesktopViewers = !desktop.isEmpty
        gateLock.unlock()
        if open, !wasOpen { onDesktopPipeClear?() }
    }

    /// Hands the slowest viewer's budget to the encoder, and its RTT to the
    /// latency readout.
    private func report(now: UInt64) {
        let desktop = viewers.values.filter(\.wantsDesktop)
        let bitrate = desktop.compactMap { viewer -> Int? in
            guard let session = endpoint.sessions[viewer.index]?.session else { return nil }
            return viewer.sender.encoderBitrate(udpPayload: session.udpPayload)
        }.min()
        let changed = switch (bitrate, lastBitrate) {
        case (nil, nil): false
        case let (new?, old?): abs(new - old) * 100 > old * 3
        default: true
        }
        if changed {
            lastBitrate = bitrate
            onTargetBitrate?(bitrate)
        }
        if now - lastLinkReport > 500_000_000, !desktop.isEmpty {
            lastLinkReport = now
            let rtt = desktop.compactMap { endpoint.sessions[$0.index]?.session.rtt.smoothed }.max() ?? 0
            onLinkLatency?(Double(rtt) / 1_000_000)
        }
        if now - lastStatsLog > 5_000_000_000, !desktop.isEmpty {
            lastStatsLog = now
            for viewer in desktop { logStatistics(viewer) }
        }
    }

    /// What the rate controller sees and does, every 5 s while a viewer
    /// watches the desktop, so a weak-link test can be read from the log.
    private func logStatistics(_ viewer: Viewer) {
        guard let session = endpoint.sessions[viewer.index]?.session else { return }
        let rate = viewer.sender.controller
        let stats = viewer.sender.statistics
        func mbps(_ bytes: UInt64?) -> String { bytes.map { String(format: "%.1f", Double($0) * 8 / 1e6) } ?? "-" }
        let line = "budget \(mbps(rate.budget.total)) Mbps (encoder \(mbps(UInt64(viewer.sender.encoderBitrate(udpPayload: session.udpPayload) / 8))), "
            + "cap \(mbps(rate.maximum))), "
            + "received \(mbps(rate.receiveRate)), delay-based \(mbps(rate.delayBasedRate)), \(rate.usage), "
            + "loss \(String(format: "%.1f", rate.smoothedLoss * 100))%, FEC \(Int(rate.budget.fecRatio * 100))%, "
            + "queue \(rate.queueingDelay / 1_000_000) ms (\(rate.baselineRebases) rebased), RTT \(String(format: "%.1f", Double(session.rtt.smoothed) / 1e6)) ms, "
            + "payload \(session.udpPayload); frames \(stats.framesQueued) queued, \(stats.framesSkipped) skipped; "
            + "shards \(stats.shardsSent) sent, \(stats.shardsResent) resent, \(stats.parityDropped) parity dropped, \(stats.probes) probes"
        log.notice("v3 link: \(line, privacy: .public)")
    }

    /// A peer with no session and nothing heard for 30 s is a stale path.
    private func sweepPeers(now: UInt64) {
        lastSweep = now
        let inUse = Set(endpoint.sessions.values.map(\.address))
        for (key, peer) in peers where !inUse.contains(key) && now - peer.lastReceive > 30_000_000_000 {
            peer.connection.cancel()
            peers[key] = nil
        }
    }
}

nonisolated private extension SessionGrants {
    init(_ grants: Set<CompanionGrant>) {
        var value = SessionGrants()
        for (bit, grant) in CompanionGrant.allCases.enumerated() where grants.contains(grant) {
            value.insert(SessionGrants(rawValue: 1 << bit))
        }
        self = value
    }
}
