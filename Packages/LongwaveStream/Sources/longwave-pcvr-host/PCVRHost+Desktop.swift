// The desktop stream over v3, beside PCVR on the same port: what the Mac
// Companion's MacNativeV3Server serves, for Windows. A session whose hello
// doesn't offer `pcvr` is a desktop viewer, in its own slot, so one headset
// can watch the desktop and run PCVR at once (HostEndpoint's slots).
//
// It follows the Companion's Native-stream switches (CompanionSettings): off,
// the desktop is refused; mouse and keyboard control each come and go with
// theirs, on top of the device's `input` grant.

import Foundation
import StreamHost
import StreamTransport
import StreamWire

final class DesktopViewer {
    let index: UInt32
    let deviceID: String
    let name: String
    let grants: SessionGrants
    var confirmed = false
    /// The hello's screen intent, then the client's `streamStart`/`streamStop` (its Screen toggle).
    var wantsScreen: Bool
    var sender = VideoStreamSender(configuration: .init(streamID: PCVRHost.desktopStreamID))
    var lastPointer: UInt32?
    var sentStatus: (mouse: RemoteControlStatus, keyboard: RemoteControlStatus)?

    init(index: UInt32, deviceID: String, hello: ClientHello, grants: SessionGrants) {
        self.index = index
        self.deviceID = deviceID
        name = hello.deviceName ?? "Longwave"
        self.grants = grants
        wantsScreen = hello.intent.contains(.screen) && grants.contains(.screen)
    }

    var wantsDesktop: Bool { confirmed && wantsScreen }
}

/// The desktop's state, under the host's lock unless said otherwise.
final class DesktopSessions {
    var viewers: [UInt32: DesktopViewer] = [:]
    var answered: [String: (hello: ClientHello, grants: SessionGrants)] = [:]
    var format: FormatDescription?
    var settings = CompanionSettings()
    var settingsRead = false
    var lastKeyFrameRequest: UInt64?
    var lastBitrate: Int?
    var lastStats: UInt64 = 0
    let input = DesktopInput()
    /// Whether every desktop viewer can take a frame; read by the capture thread.
    private let gateLock = NSLock()
    private var gateOpen = true

    var canSend: Bool { gateLock.withLock { gateOpen } }

    /// Sets the gate; true when it just opened.
    func setGate(_ open: Bool) -> Bool {
        gateLock.withLock {
            defer { gateOpen = open }
            return open && !gateOpen
        }
    }
}

extension PCVRHost {
    static let desktopStreamID: UInt32 = 0
    /// HostEndpoint slots: the desktop, and the PCVR profile's session.
    static let desktopSlot: UInt8 = 0
    static let pcvrSlot: UInt8 = 1
    /// What the desktop offers: HEVC is the baseline; 4:2:0 only.
    static let desktopCapabilities = CapabilitySet([.nack])
    private static let desktopKeyFrameInterval: UInt64 = 250_000_000
    /// The desktop's encoder never asks for more than this (bits/s).
    static let desktopMaxBitrate = 40_000_000

    static func slot(of hello: ClientHello) -> UInt8 {
        hello.capabilities.contains(.pcvr) ? pcvrSlot : desktopSlot
    }

    /// The grants a desktop viewer gets: its device's, less what the Companion's switches turn off.
    func desktopGrants(device: SessionGrants) -> SessionGrants {
        let settings = desktop.settings
        guard settings.desktopEnabled, device.contains(.screen) else { return [] }
        var grants = device
        if !settings.mouseControl, !settings.keyboardControl { grants.remove(.input) }
        return grants
    }

    func desktopAck(answering hello: ClientHello, grants: SessionGrants) -> HostHelloAck {
        HostHelloAck(answering: hello, hostCapabilities: Self.desktopCapabilities, platform: .windows,
                     keyCodeSpace: .hidUsage, grants: grants, maxUDPPayload: DatagramLayout.maxProbedUDPPayload,
                     hostName: String(ProcessInfo.processInfo.hostName.prefix(HelloLimits.maxNameBytes)),
                     software: "Longwave stream host")
    }

    // MARK: Sessions (under `lock`)

    func desktopConnected(index: UInt32, deviceID: String, now: UInt64) {
        guard let (hello, grants) = desktop.answered.removeValue(forKey: deviceID) else { return }
        guard !grants.isEmpty else {
            endpoint.remove(index)
            return
        }
        let viewer = DesktopViewer(index: index, deviceID: deviceID, hello: hello, grants: grants)
        desktop.viewers[index] = viewer
        _ = endpoint.withSession(index) { $0.setPathCeiling(DatagramLayout.maxProbedUDPPayload, now: now) }
        if let udpPayload = endpoint.sessions[index]?.session.udpPayload {
            viewer.sender.setEncoderCeiling(Self.desktopMaxBitrate, udpPayload: udpPayload)
        }
    }

    func desktopConfirmed(_ viewer: DesktopViewer, now: UInt64) {
        guard !viewer.confirmed else { return }
        viewer.confirmed = true
        log.line("desktop viewer '\(viewer.name)' connected from \(endpoint.sessions[viewer.index]?.address.description ?? "?")")
        sendInputStatus(to: viewer)
        if viewer.wantsScreen { subscribe(viewer, now: now) }
    }

    /// A viewer joins the desktop: the capture starts for the first, the rest get the format and a key frame.
    private func subscribe(_ viewer: DesktopViewer, now: UInt64) {
        if desktopCapture.isRunning {
            sendDesktopFormat(to: viewer)
            desktop.lastKeyFrameRequest = nil
            requestDesktopKeyFrame(now: now)
            return
        }
        do {
            try desktopCapture.start()
            desktop.input.origin = desktopCapture.origin ?? (0, 0)
        } catch {
            log.line("desktop: could not capture: \(error)")
            endDesktopSession(viewer, reason: "This PC couldn't capture its screen (\(error)).")
        }
    }

    private func stopDesktopIfUnwatched() {
        guard desktopCapture.isRunning, !desktop.viewers.values.contains(where: \.wantsDesktop) else { return }
        desktopCapture.stop()
        desktop.format = nil
        desktop.lastBitrate = nil
    }

    func desktopHandle(_ events: [SessionEvent], from viewer: DesktopViewer, now: UInt64) {
        for event in events {
            switch event {
            case .message(.input, let message):
                guard let input = try? TimedInputEvent(message: message) else { continue }
                inject(input.event, from: viewer)
            case .message(.control, let message):
                desktopControl(message, from: viewer, now: now)
            case .state(let snapshot):
                guard allowsMouse(viewer), case .pointerAbsolute(let pointer) = snapshot.payload else { continue }
                if let last = viewer.lastPointer, !SerialNumber.isNewer(snapshot.sequence, than: last) { continue }
                viewer.lastPointer = snapshot.sequence
                desktop.input.move(x: pointer.x, y: pointer.y)
            case .nack(let nack):
                viewer.sender.handle(nack)
            case .feedback(_, let results):
                let rtt = endpoint.sessions[viewer.index]?.session.rtt.smoothed ?? 2_000_000
                viewer.sender.onFeedback(results, now: now, rtt: rtt)
            case .message, .video, .audio:
                continue
            }
        }
    }

    private func allowsMouse(_ viewer: DesktopViewer) -> Bool {
        viewer.grants.contains(.input) && desktop.settings.mouseControl
    }

    private func allowsKeyboard(_ viewer: DesktopViewer) -> Bool {
        viewer.grants.contains(.input) && desktop.settings.keyboardControl
    }

    private func inject(_ event: InputEvent, from viewer: DesktopViewer) {
        let input = desktop.input
        switch event {
        case .keyDown(let key) where allowsKeyboard(viewer): input.key(hidUsage: key.keyCode, down: true)
        case .keyUp(let key) where allowsKeyboard(viewer): input.key(hidUsage: key.keyCode, down: false)
        case .mouseDown(let e) where allowsMouse(viewer): input.button(e.button, down: true, x: e.x, y: e.y)
        case .mouseUp(let e) where allowsMouse(viewer): input.button(e.button, down: false, x: e.x, y: e.y)
        case .scroll(let s) where allowsMouse(viewer): input.scroll(x: s.x, y: s.y, lines: (s.lineDeltaX, s.lineDeltaY))
        case .releaseAll: input.releaseAll()
        default: break
        }
    }

    private func desktopControl(_ message: Message, from viewer: DesktopViewer, now: UInt64) {
        switch message.type {
        case .recoveryRequest:
            guard viewer.wantsDesktop, (try? RecoveryRequest(decoding: message.body)) != nil else { return }
            viewer.sender.recoveryRequested()
            requestDesktopKeyFrame(now: now)
        case .streamStart:
            guard viewer.grants.contains(.screen), !viewer.wantsScreen,
                  let subscription = try? StreamSubscription(decoding: message.body),
                  subscription.streamID == Self.desktopStreamID else { return }
            viewer.wantsScreen = true
            subscribe(viewer, now: now)
        case .streamStop:
            guard viewer.wantsScreen, let subscription = try? StreamSubscription(decoding: message.body),
                  subscription.streamID == Self.desktopStreamID else { return }
            viewer.wantsScreen = false
            stopDesktopIfUnwatched()
        case .bye:
            endpoint.remove(viewer.index)
            removeDesktopViewer(viewer, reason: "viewer said goodbye")
        default:
            break
        }
    }

    private func sendDesktopFormat(to viewer: DesktopViewer) {
        guard var format = desktop.format else { return }
        format.firstFrameNumber = viewer.sender.upcomingFrameNumber
        viewer.sender.recoveryRequested()
        guard let body = try? format.encoded() else { return }
        _ = endpoint.withSession(viewer.index) { try? $0.send(.formatDescription, body: body, on: .control) }
    }

    private func requestDesktopKeyFrame(now: UInt64) {
        if let last = desktop.lastKeyFrameRequest, now - last < Self.desktopKeyFrameInterval { return }
        desktop.lastKeyFrameRequest = now
        desktopCapture.requestKeyFrame()
    }

    private func sendInputStatus(to viewer: DesktopViewer) {
        let mouse: RemoteControlStatus = allowsMouse(viewer) ? .available : .disabled
        let keyboard: RemoteControlStatus = allowsKeyboard(viewer) ? .available : .disabled
        if let sent = viewer.sentStatus, sent.mouse == mouse, sent.keyboard == keyboard { return }
        viewer.sentStatus = (mouse, keyboard)
        for event in [HostInputEvent.controlStatus(.mouse, mouse), .controlStatus(.keyboard, keyboard)] {
            var body = WireWriter(reservingCapacity: 4)
            guard (try? event.encodeBody(to: &body)) != nil else { continue }
            _ = endpoint.withSession(viewer.index) { try? $0.send(event.messageType, body: body.bytes, on: .input) }
        }
    }

    /// The Companion's switches changed: the desktop's viewers go when it's
    /// turned off, and hear about the pointer and keyboard otherwise.
    func applyDesktopSettings(_ settings: CompanionSettings) {
        guard settings != desktop.settings || !desktop.settingsRead else { return }
        desktop.settings = settings
        desktop.settingsRead = true
        log.line("desktop: \(settings.desktopEnabled ? "on" : "off (the Companion's Native stream switch)"), mouse \(settings.mouseControl ? "on" : "off"), "
                 + "keyboard \(settings.keyboardControl ? "on" : "off")")
        for viewer in Array(desktop.viewers.values) {
            if !settings.desktopEnabled {
                endDesktopSession(viewer, reason: "Screen streaming was turned off on this PC.")
            } else if viewer.confirmed {
                sendInputStatus(to: viewer)
            }
        }
    }

    func endDesktopSession(_ viewer: DesktopViewer, reason: String) {
        if let body = try? TextBody.encode(reason) {
            _ = endpoint.withSession(viewer.index) { try? $0.send(.bye, body: body, on: .control) }
        }
        flush(now: Self.now())
        endpoint.remove(viewer.index)
        removeDesktopViewer(viewer, reason: "ended by the host")
    }

    func removeDesktopViewer(_ viewer: DesktopViewer, reason: String) {
        guard desktop.viewers.removeValue(forKey: viewer.index) != nil else { return }
        if viewer.confirmed {
            log.line("desktop viewer '\(viewer.name)' left: \(reason)")
            if allowsMouse(viewer) || allowsKeyboard(viewer) { desktop.input.releaseAll() }
        }
        stopDesktopIfUnwatched()
    }

    // MARK: Frames

    /// An encoded desktop frame, from the capture thread.
    func desktopFrame(_ encoded: DesktopCapture.Encoded) {
        lock.withLock {
            let now = Self.now()
            if let format = encoded.format, format != desktop.format {
                desktop.format = format
                for viewer in desktop.viewers.values where viewer.wantsDesktop { sendDesktopFormat(to: viewer) }
            }
            var wantsKey = false
            for viewer in desktop.viewers.values where viewer.wantsDesktop {
                guard let udpPayload = endpoint.sessions[viewer.index]?.session.udpPayload else { continue }
                do {
                    switch try viewer.sender.submit(accessUnit: encoded.sample, isKeyFrame: encoded.isKeyFrame,
                                                    captureTime: encoded.captureTime, udpPayload: udpPayload, now: now) {
                    case .queued: break
                    case .awaitingKeyFrame, .queueFull: wantsKey = true
                    }
                } catch {
                    log.line("desktop: could not shard a frame: \(error)")
                }
            }
            if wantsKey { requestDesktopKeyFrame(now: now) }
            pump()
        }
    }

    /// Each desktop viewer's paced media, the encoder's budget and the gate.
    func desktopPump(now: UInt64) {
        let watching = desktop.viewers.values.filter(\.wantsDesktop)
        for viewer in watching {
            guard let address = endpoint.sessions[viewer.index]?.address else { continue }
            while let output = viewer.sender.next(now: now) {
                let datagram: [UInt8]?? = endpoint.withSession(viewer.index) { session in
                    switch output {
                    case .shard(let header, let data): try? session.sealVideo(header, data: data, now: now)
                    case .padding(let size, let cluster): try? session.sealPadding(size: size, probeCluster: cluster, now: now)
                    }
                }
                if let datagram = datagram ?? nil { socket.send(datagram, to: address) }
            }
        }
        let bitrate = watching.compactMap { viewer -> Int? in
            guard let session = endpoint.sessions[viewer.index]?.session else { return nil }
            return viewer.sender.encoderBitrate(udpPayload: session.udpPayload)
        }.min()
        if let bitrate, bitrate != desktop.lastBitrate {
            desktop.lastBitrate = bitrate
            desktopCapture.setBitrate(min(bitrate, Self.desktopMaxBitrate))
        }
        if desktop.setGate(watching.allSatisfy(\.sender.canAcceptFrame)) { desktopCapture.pipeCleared() }
        if now &- desktop.lastStats > 10_000_000_000, !watching.isEmpty {
            desktop.lastStats = now
            for viewer in watching {
                let stats = viewer.sender.statistics
                let rtt = Double(endpoint.sessions[viewer.index]?.session.rtt.smoothed ?? 0) / 1e6
                log.line("desktop '\(viewer.name)': \(String(format: "%.1f", Double(bitrate ?? 0) / 1e6)) Mbps, "
                         + "\(stats.framesQueued) frames, \(stats.framesSkipped) skipped, \(stats.shardsResent) resent, "
                         + "RTT \(String(format: "%.1f", rtt)) ms")
            }
        }
    }

    func desktopNextWake(now: UInt64) -> UInt64? {
        desktop.viewers.values.filter(\.wantsDesktop).compactMap { $0.sender.nextWakeTime(now: now) }.min()
    }
}
