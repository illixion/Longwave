import Foundation
import AppKit
import Observation

/// Owns the KVM dongle: which serial port it is on, whether the headset is
/// paired and listening, and whether this Mac's keyboard and mouse are
/// currently being sent to it.
///
/// visionOS gives apps no way to inject input, so a Bluetooth HID device the
/// headset pairs with the way it would pair with any keyboard is the only route
/// from the Mac side. `KVMInputCapture` takes the events, this drains them into
/// `KVMDongleLink`, and the ESP32 does the Bluetooth half.
@Observable
final class KVMBridgeController {

    // MARK: - Settings

    private enum Key {
        static let port = "kvmDonglePort"
        static let autoConnect = "kvmAutoConnect"
        static let pointerSpeed = "kvmPointerSpeed"
    }

    /// The device path the user picked. Serial device numbers change when the
    /// board re-enumerates, so this is a hint: if it is gone at connect time,
    /// the only candidate present wins.
    var portPath: String {
        get {
            access(keyPath: \.portPath)
            return UserDefaults.standard.string(forKey: Key.port) ?? ""
        }
        set {
            withMutation(keyPath: \.portPath) {
                UserDefaults.standard.set(newValue, forKey: Key.port)
            }
        }
    }

    /// Whether to claim the port at launch. Off by default: opening it takes it
    /// exclusively, which would lock `kvmctl.py` (and a second copy of this
    /// app) out of a board the user may be working on.
    var autoConnect: Bool {
        get {
            access(keyPath: \.autoConnect)
            return UserDefaults.standard.bool(forKey: Key.autoConnect)
        }
        set {
            withMutation(keyPath: \.autoConnect) {
                UserDefaults.standard.set(newValue, forKey: Key.autoConnect)
            }
        }
    }

    var pointerSpeed: Double {
        get {
            access(keyPath: \.pointerSpeed)
            let stored = UserDefaults.standard.double(forKey: Key.pointerSpeed)
            return stored > 0 ? stored : 1.0
        }
        set {
            withMutation(keyPath: \.pointerSpeed) {
                UserDefaults.standard.set(newValue, forKey: Key.pointerSpeed)
            }
            capture.pointerSpeed = newValue
        }
    }

    // MARK: - Observable state

    private(set) var ports: [String] = []
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var status: KVMDongleLink.Status?
    private(set) var lastError: String?
    /// The most recent thing the dongle said — events and its own log lines.
    private(set) var activity: [String] = []
    private(set) var isCapturing = false
    private(set) var roundTrip: Duration?

    /// Whether the headset is paired, connected and listening for reports.
    var headsetIsListening: Bool { status?.acceptsInput ?? false }

    var summary: String {
        if !isConnected { return isConnecting ? "Connecting…" : "Not connected" }
        guard let status else { return "Connected" }
        if isCapturing { return "Sending this Mac's keyboard and mouse" }
        return status.acceptsInput ? "Ready — headset paired" : status.state.title
    }

    static let toggleShortcutDescription = "⌃⌥⌘K"

    // MARK: - Internals

    private let capture = KVMInputCapture()
    private var link: KVMDongleLink?
    private var sender: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    init() {
        capture.pointerSpeed = pointerSpeed
        capture.onToggleHotkey = { [weak self] in
            guard let self else { return }
            self.setCapturing(!self.isCapturing)
        }
        capture.onTapReenabled = { [weak self] in
            self?.note("macOS disabled the input tap; re-enabled it")
        }
        refreshPorts()
        if autoConnect, !ports.isEmpty {
            Task { await self.connect() }
        }
    }

    func refreshPorts() {
        ports = KVMDongleLink.availablePorts()
        if portPath.isEmpty || !ports.contains(portPath) {
            portPath = ports.first ?? ""
        }
    }

    // MARK: - Connecting

    func connect() async {
        guard !isConnected, !isConnecting else { return }
        refreshPorts()
        guard !portPath.isEmpty else {
            lastError = "No USB serial device found. Plug the dongle in."
            return
        }
        isConnecting = true
        lastError = nil
        let link = KVMDongleLink()
        do {
            let opened = try await link.open(path: portPath) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            self.link = link
            status = opened
            isConnected = true
            isConnecting = false
            note("connected on \(portPath), firmware \(opened.firmware)")
            try? capture.arm()
            startPolling()
        } catch {
            isConnecting = false
            link.close()
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        setCapturing(false)
        capture.disarm()
        poller?.cancel()
        poller = nil
        link?.close()
        link = nil
        isConnected = false
        status = nil
        roundTrip = nil
    }

    private func handle(_ event: KVMDongleLink.Event) {
        switch event {
        case .boot(let firmware):
            note("dongle rebooted, firmware \(firmware)")
            refreshStatusSoon()
        case .advertising:
            note("advertising — pair “Longwave KVM” from the headset")
            refreshStatusSoon()
        case .connected:
            note("headset connected")
            refreshStatusSoon()
        case .encrypted(let bonded):
            note(bonded ? "paired and encrypted" : "encrypted, not bonded")
            refreshStatusSoon()
        case .disconnected(let reason):
            note("headset disconnected (reason 0x\(String(reason, radix: 16)))")
            // Nothing is listening any more, and whatever was held down is
            // gone with the link — stop pretending otherwise.
            setCapturing(false)
            refreshStatusSoon()
        case .leds, .subscribed:
            refreshStatusSoon()
        case .log(let line):
            note(line)
        case .closed(let reason):
            note(reason.map { "serial link lost: \($0)" } ?? "serial link closed")
            disconnect()
        }
    }

    private func note(_ line: String) {
        activity.append(line)
        if activity.count > 60 { activity.removeFirst(activity.count - 60) }
    }

    var recentActivity: [String] { Array(activity.suffix(6)) }

    // MARK: - Status

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let link = self.link else { return }
                do {
                    let fresh = try await link.status()
                    self.status = fresh
                    if self.isCapturing && !fresh.acceptsInput {
                        self.setCapturing(false)
                        self.lastError = "The headset stopped listening."
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // A dead link surfaces through the `.closed` event; a lone
                    // timeout is not worth tearing anything down for.
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshStatusSoon() {
        Task { [weak self] in
            guard let self, let link = self.link else { return }
            if let fresh = try? await link.status() { self.status = fresh }
        }
    }

    // MARK: - Capture

    func setCapturing(_ capturing: Bool) {
        guard capturing != isCapturing else { return }
        if capturing {
            guard let link, isConnected else {
                lastError = "Connect the dongle first."
                return
            }
            guard headsetIsListening else {
                lastError = "The headset is not paired with the dongle yet."
                return
            }
            do {
                try capture.arm()
            } catch {
                lastError = error.localizedDescription
                return
            }
            lastError = nil
            isCapturing = true
            capture.setCapturing(true)
            note("capturing — press \(Self.toggleShortcutDescription) to stop")
            startSending(on: link)
        } else {
            isCapturing = false
            capture.setCapturing(false)
            sender?.cancel()
            sender = nil
            if let link {
                Task { try? await link.releaseAll() }
            }
            note("stopped capturing")
        }
    }

    /// Drains the capture queues for as long as capture is on.
    ///
    /// There is no timer: each send awaits its acknowledgement, so the loop
    /// runs exactly as fast as the link drains (~3 ms a frame) and pointer
    /// motion coalesces behind it on its own. Key reports go first — a release
    /// that waits behind a pointer frame is a key stuck down on the headset.
    private func startSending(on link: KVMDongleLink) {
        sender?.cancel()
        sender = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCapturing else { return }
                do {
                    if let item = self.capture.takePending() {
                        switch item {
                        case .key(let report):
                            try await link.sendKeyboard(report)
                        case .consumer(let usage, let pressed):
                            try await link.sendConsumer(usage: usage, pressed: pressed)
                        }
                        continue
                    }
                    if let move = self.capture.takeMotion() {
                        try await link.sendMouse(dx: move.dx, dy: move.dy,
                                                 buttons: move.buttons,
                                                 wheel: move.wheel, pan: move.pan)
                        continue
                    }
                } catch is CancellationError {
                    return
                } catch {
                    let failure = error as? KVMDongleLink.Failure
                    if failure?.isReportUnsubscribed == true {
                        // One report kind the headset has not switched on yet.
                        // The rest of the session is still worth having, so say
                        // so and keep going rather than dropping capture.
                        self.lastError = "The headset is not listening to every report yet."
                        continue
                    }
                    self.lastError = failure?.isHeadsetAbsent == true
                        ? "The headset is not receiving input."
                        : error.localizedDescription
                    self.setCapturing(false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
    }

    // MARK: - Manual actions

    func measureRoundTrip() async {
        guard let link else { return }
        do {
            roundTrip = try await link.ping()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func releaseEverything() async {
        guard let link else { return }
        do {
            try await link.releaseAll()
            note("released every key and button")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Types a short string on the headset, to prove the whole path end to end
    /// without having to hand the Mac's keyboard over first.
    func sendTestPhrase() async {
        guard let link else { return }
        do {
            for character in "longwave kvm" {
                guard let usage = MacKeyCodeMap.hidUsage(typing: character),
                      let byte = UInt8(exactly: usage) else { continue }
                var report = [UInt8](repeating: 0, count: 8)
                report[2] = byte
                try await link.sendKeyboard(report)
                try await link.sendKeyboard(KVMInputCapture.releasedKeyboardReport)
            }
            note("typed a test phrase")
            lastError = nil
        } catch {
            lastError = (error as? KVMDongleLink.Failure)?.isHeadsetAbsent == true
                ? "The headset is not receiving input."
                : error.localizedDescription
        }
    }

    /// Drops the dongle's half of the pairing. The headset keeps its own until
    /// the user forgets the device there too, and will otherwise keep trying to
    /// reconnect with a key the dongle no longer holds.
    func forgetPairing() async {
        guard let link else { return }
        setCapturing(false)
        do {
            try await link.forgetBonds()
            note("pairing cleared — also forget “Longwave KVM” on the headset")
        } catch {
            lastError = error.localizedDescription
        }
    }
}
