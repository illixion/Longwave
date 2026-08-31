//  ControllerBridgeSender.swift
//
//  visionOS half of the Longwave Controller Bridge. While a foveated PCVR
//  session is live, this streams the user's hand-tracking wrist poses (ARKit
//  `HandTrackingProvider`) plus controller inputs to the host
//  (`cb_input_state_t`, packet 0x03 — see ControllerBridgeProtocol.swift). The
//  host presents the same state as emulated OpenXR controllers (Oculus Touch
//  preferred, Valve Index fallback), an optional Xbox 360 controller, or both.
//  The OpenXR controllers stay positioned at the hands, so PCVR titles without
//  skeletal-hand support still get full controllers.
//
//  Transport: UDP :9520 for the poses, and the TCP control link (:9523,
//  `BridgeControlLink`) for everything else — haptics, telemetry, perf, the game
//  library, debug tuning. The session's `MessageChannel` (CloudXR opaque data
//  channel) is the rendezvous only.
//
//  The channel is not durable. On the CloudXR host a connection lasts about twelve
//  seconds regardless of traffic (13.0 s / 12.1 s / 12.2 s, measured 2026-07-27),
//  after which sends fall back to UDP and input keeps working. That is why the
//  channel's only job is now the rendezvous: the host announces its addresses and
//  a session token on it (`cb_rendezvous_t`) every two seconds, and everything real
//  runs on the direct link rather than depending on the channel surviving.
//
//  Three input sources fill the button/stick fields, and they coexist:
//    - Spatial controllers (PSVR2 Sense etc., `SpatialAccessoryTracker`): real
//      per-hand 6DoF poses + gyros + buttons; a tracked one replaces the
//      wrist-derived pose for its hand. Best-effort — dormant without hardware.
//    - A physical Switch Pro controller (`GameController`), when connected.
//    - Per-finger thumb pinches (`HandGestureEngine` + `GestureControllerMapping`),
//      which make the physical controller OPTIONAL: right index tap = trigger,
//      right middle/ring/little = A/B/menu, left middle/ring/little = X/Y/L-trigger,
//      and left thumb+index = a wrist-delta locomotion joystick (left = movement,
//      mirroring a real controller). Fully remappable; covers the minimal
//      ABXY + triggers + menu set most games want.
//
//  Gated behind FOVEATED_ENABLED. Hand tracking requires the app to be in an
//  immersive space and the user to grant hand-tracking authorization; the gyro
//  needs a controller that reports motion (the Switch Pro does). None of this
//  needs the foveated-streaming entitlement, so the bridge can be exercised
//  independently of CloudXR for testing.
//
//  The controller's IMU is attributed to a specific hand before being sent — see
//  ControllerHandAssignment. Sending one gyro as though it described both wrists is
//  right for a two-handed gamepad grip and wrong for a controller held like a wand,
//  and the host cannot tell the difference because it can see neither the wrists nor
//  the controller. So the decision is made here and travels as two flag bits.
//
//  Coordinate-space alignment is structural rather than calibrated: this side reports
//  ARKit-world grip poses and skeletons, and the host anchors them to its STAGE space
//  (see the PCVR design notes in Longwave-PCVR-Host/docs/). Verified on device — real
//  wrist poses reach the game, at the palm rather than the wrist.

#if FOVEATED_ENABLED
import Foundation
import Network
import RAVEInput
import simd
import os
import GameController
import CoreHaptics
import ARKit
import QuartzCore

#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

@MainActor
@Observable
final class ControllerBridgeSender {

    private let host: String
    private let log = Logger(subsystem: "pro.longwave", category: "ControllerBridge")

    /// Most recent tracked wrist poses, written by the ARKit update loop.
    private var leftHand: ControllerBridgeHandPose?
    private var rightHand: ControllerBridgeHandPose?

    /// Most recent full 26-joint skeletons (XR_EXT order), same update loop. These feed
    /// the 0x04 packet so games with real hand-tracking support get per-finger hands.
    /// Readable so the alignment HUD can draw exactly what we ship — spheres landing on
    /// the real hand prove the sender is right and the residual is all host-side.
    private(set) var leftJoints: [ControllerBridgeJoint]?
    private(set) var rightJoints: [ControllerBridgeJoint]?
    private var jointsSequence: UInt8 = 0
    private var sendJointsThisTick = false

    /// Hand-gesture controller emulation (makes the physical controller optional).
    ///
    /// Fed rather than self-starting: this class already runs a `HandTrackingProvider`
    /// for pose streaming and joint forwarding, so anchors are pushed in through
    /// `ingest(_:)` and a second ARKit session is never opened.
    private let gestureEngine = RAVEARKitHandSensor()
    private var gestureMapping = GestureControllerMappingStore.load()

    // MARK: Physical controller (Switch Pro)
    //
    // Held rather than looked up per tick. The old code called
    // `GCController.current ?? GCController.controllers().first` inside the 83 Hz packet
    // builder, which had two faults beyond the waste: `.first` is whatever order the
    // framework happens to return, so a non-gamepad (a remote, a keyboard-ish device)
    // sitting ahead of the pad silently produced no input at all and nothing said why;
    // and there was no connect notification, so nothing could react to a controller
    // arriving or leaving. MoonlightGamepadManager has done this properly since it was
    // written — this is the same pattern.

    /// The controller we are reading, and its motion sensor if it has one.
    private(set) var controller: GCController?
    private var controllerObservers: [NSObjectProtocol] = []

    /// Spatial controllers (PSVR2 Sense etc.) — their own discovery, their own
    /// ARKit provider, per-hand rather than adopted-singular. See the class doc.
    let spatialTracker = SpatialAccessoryTracker()

    /// Nil when no controller is attached or the attached one reports no rotation rate.
    /// A Switch Pro does report one; not every extended gamepad does, and reading
    /// `rotationRate` on a device without it yields a constant zero that would look like
    /// a perfectly still controller rather than an absent sensor.
    private var motion: GCMotion?

    /// Which hand the controller's IMU is attributed to, and how that was decided.
    private var handDetector = ControllerHandDetector()
    private(set) var handPreference = ControllerHandPreferenceStore.load()

    /// The holder in force: the user's override if they set one, else the detector's
    /// verdict. `.unknown` means no gyro is sent — see `buildPacket`.
    var controllerHolder: ControllerHolder {
        guard motion != nil else { return .unknown }
        return handPreference.forced ?? handDetector.holder
    }

    /// Detector confidence for the HUD (nil until it has judged).
    var controllerHandScores: (left: Float?, right: Float?) {
        (handDetector.leftScore, handDetector.rightScore)
    }

    /// True when a controller is attached and reporting motion.
    var controllerHasMotion: Bool { motion != nil }

    /// Battery readouts for the wrist HUD — one per physical device the bridge is
    /// reading (the adopted gamepad plus any spatial controllers). Polled rather
    /// than observed: the HUD redraws on its own 10 Hz clock and a battery moves
    /// on the order of minutes, so nothing here is worth a KVO subscription.
    struct BatteryReadout: Identifiable, Equatable {
        let id: String
        let label: String
        let level: Float          // 0…1
        let charging: Bool
    }

    var batteryReadouts: [BatteryReadout] {
        var readouts: [BatteryReadout] = []
        func append(_ device: GCController, id: String, label: String) {
            // No battery object, unknown state, or a negative level all mean the
            // same thing to a reader: nothing trustworthy to show, so show nothing.
            guard let battery = device.battery, battery.batteryLevel >= 0,
                  battery.batteryState != .unknown else { return }
            readouts.append(BatteryReadout(id: id, label: label,
                                           level: battery.batteryLevel,
                                           charging: battery.batteryState == .charging))
        }
        if let controller { append(controller, id: "pad", label: "pad") }
        if let left = spatialTracker.controllers[.left] {
            append(left, id: "spatial-left", label: "left pad")
        }
        if let right = spatialTracker.controllers[.right] {
            append(right, id: "spatial-right", label: "right pad")
        }
        return readouts
    }

    func setHandPreference(_ preference: ControllerHandPreference) {
        guard preference != handPreference else { return }
        handPreference = preference
        ControllerHandPreferenceStore.save(preference)
        // Going back to automatic must not inherit a verdict formed while the override
        // was doing the deciding; nothing was being measured against.
        if preference == .auto { handDetector.reset() }
    }

    /// Wrist orientations and timestamps from the previous tick, for angular speed.
    private var lastWristRotation: [BridgeHand: (rotation: simd_quatf, at: CFTimeInterval)] = [:]
    private var wristAngularSpeed: [BridgeHand: Float] = [:]

    /// The measured grip frame expressed in the hand anchor's frame, per hand — the
    /// user's own palm geometry, held as a rigid offset. See `gripPose(from:)`.
    private var anchorFromGrip: [BridgeHand: (rotation: simd_quatf, position: SIMD3<Float>)] = [:]

    /// Per-hand wrist-tracking confidence (1–255) for the pose currently in
    /// `leftHand`/`rightHand`, from per-joint `isTracked` over the grip-basis joints.
    /// The host weights its continuous Quest-calibration pairs by this — it cannot
    /// judge occlusion itself, and we are holding the skeleton that can.
    private var gripConfidence: [BridgeHand: UInt8] = [:]

    private var sequence: UInt8 = 0

    // Networking. The datagram channel owns the socket, the seal and the plaintext
    // policy, and runs them on its own queue — see BridgeDatagramChannel.
    private let datagram = BridgeDatagramChannel()

    /// Preferred transport: the foveated session's message channel (the host
    /// API layer's opaque data channel). Attached by the manager when the
    /// bridge channel appears; UDP is the fallback while nil / not ready.
    private var messageChannel: FoveatedStreamingSession.MessageChannel?
    private var channelReceiveTask: Task<Void, Never>?

    /// Set by the game library. The channel's only real job now: the host puts a
    /// `cb_rendezvous_t` on it every two seconds, and everything else — input,
    /// haptics, the library — runs over UDP. The channel itself lasts about twelve
    /// seconds per connection on the CloudXR host, so it can only be trusted with a
    /// handover.
    var rendezvousHandler: ((ControllerBridgeRendezvous) -> Void)?
    /// Called when a channel is (re)attached, so the library can re-ask: its
    /// state is a snapshot of the host, and the host may have changed.
    var onChannelAttached: (() -> Void)?

    /// Called with the host's alpha-blend state on the first telemetry and whenever it
    /// changes, so the immersive space can move between mixed and progressive to match.
    /// A callback rather than something the views poll: the space has to restyle even
    /// when nobody is looking at the PCVR tab.
    var onAlphaBlendChanged: ((Bool) -> Void)?

    /// The TCP link carrying everything that is not hand tracking: the game library,
    /// the perf feed, telemetry, haptics and tuning. Owned here because the rendezvous
    /// and the session keys arrive here, and because the perf and haptic packets that
    /// come back are this object's business.
    let control = BridgeControlLink()

    /// Called when the control link connects or reconnects, with the endpoint that
    /// answered. The library re-asks on this: its contents are a snapshot of a host
    /// that may have restarted underneath it.
    var onControlReady: ((String) -> Void)?

    /// The token the current keys came from, so a re-announcement of the same session
    /// does not silently reset the seal's counters — see `adopt(rendezvous:)`.
    private var adoptedToken: Data?
    /// Where UDP goes once an endpoint has proven itself. `host` from `init` is the
    /// pre-rendezvous default: a hard-coded address for the dev/testing path, and
    /// empty for a session the system discovered.
    private var directHost: String?
    /// The input port the host announced (its actual bind, which is not necessarily
    /// the fixed constant — see cb_rendezvous_t).
    private var announcedInputPort: UInt16 = ControllerBridgeProtocol.portInput

    /// Adopt the host's rendezvous: derive the session keys and connect the control
    /// link. The UDP endpoint follows from the control link's connect — a TCP
    /// connection that completes is the only reachability test worth running, and it
    /// replaces the speculative UDP probing the library used to do.
    func adopt(rendezvous: ControllerBridgeRendezvous) {
        control.adopt(rendezvous)
        announcedInputPort = rendezvous.inputPort
        // Input is sealed or it does not flow: a host whose key-holding process does
        // not own the input port cannot open what we seal, and plaintext input on a
        // LAN is not an acceptable fallback (the dev opt-in lives in the datagram
        // channel). The channel carries what input it can in the meantime.
        guard rendezvous.sealsInput else {
            if adoptedToken != nil {
                log.notice("Rendezvous: host does not open sealed input; withholding UDP input (channel only).")
            }
            datagram.clearSeal()
            adoptedToken = nil
            return
        }
        /* Only when the token actually changes, and that is not an optimisation.

           A `BridgeSeal` is the counters as much as the keys: the nonce is the send
           counter, and a fresh seal starts it at 1. The host re-announces the same
           rendezvous every two seconds and keeps a 64-packet replay window, so
           re-deriving on each announcement restarted our counter at 1 while the host's
           window sat somewhere past 400 — every packet after that looked like a stale
           replay and was refused. Sealed input therefore died about two seconds into
           every session, permanently, and the host log filled with "refused N sealed
           datagram(s) that did not authenticate" (35,000 of them in one session on
           2026-07-29). It was invisible for as long as it was because the host falls
           back to the runtime's own wrists — the poses kept looking plausible while
           nothing we sent was being read. A new token really is a new session and does
           want fresh counters; the same token twice does not. */
        guard rendezvous.token != adoptedToken else { return }
        adoptedToken = rendezvous.token
        // `.datagram` keys, distinct from the control link's — see BridgeSeal.Channel.
        datagram.adoptToken(rendezvous.token)
        log.notice("Rendezvous: session keys adopted for sealed input.")
    }

    /// Point the UDP input stream at the endpoint the control link proved reachable,
    /// on the port the rendezvous announced.
    func useDirectEndpoint(_ endpoint: String) {
        guard endpoint != directHost else { return }
        directHost = endpoint
        datagram.setEndpoint(host: endpoint, port: announcedInputPort)
    }

    /// True once the channel is usable. Only the rendezvous rides it now, so this
    /// says "a handover is possible", not "the library can talk".
    var isChannelReady: Bool { messageChannel?.channelStatus == .ready }

    // Haptics (driver → Switch Pro rumble), keyed by controller side (0 = left, 1 = right).
    private var hapticEngines: [UInt8: CHHapticEngine] = [:]
    private var hapticPlayers: [UInt8: any CHHapticPatternPlayer] = [:]
    /// Which device each side's cached engine was built against — per side, because
    /// a Sense pair is two devices, and a single shared owner would tear down both
    /// engines on every alternating left/right pulse.
    private var hapticEngineOwners: [UInt8: ObjectIdentifier] = [:]
    private var lastHapticTime: [UInt8: CFTimeInterval] = [:]

    // Tasks
    private var handTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private let arSession = ARKitSession()
    private let handProvider = HandTrackingProvider()
    private let worldProvider = WorldTrackingProvider()

    /// Observable status for any debug UI.
    private(set) var isRunning = false
    private(set) var lastSendError: String?

    // MARK: Alignment debugging
    //
    // Hand alignment can only be judged from inside the headset (the VR hand has to be
    // seen against the real one), so the host streams its solved transform back (0x07)
    // and takes live nudges (0x08) from `FoveatedAlignmentDebugView`.

    /// Latest host telemetry, nil until the first packet arrives.
    private(set) var telemetry: ControllerBridgeTelemetry?
    private(set) var telemetryReceivedAt: CFTimeInterval = 0

    // MARK: Performance readout (0x0C)

    /// Latest perf packet, nil until the host starts sending them (channel, or UDP if the
    /// channel is down — it was UDP-only, which meant it only arrived in degraded sessions).
    private(set) var perf: ControllerBridgePerf?
    private(set) var perfReceivedAt: CFTimeInterval = 0

    /// Rolling host frame periods in milliseconds, oldest first — the HUD's graph.
    /// Two seconds at 90 Hz, which is long enough for a stutter to still be on screen
    /// when the user looks down at their wrist to find out what happened.
    private(set) var framePeriodHistory: [Float] = []
    static let framePeriodHistoryLength = 180

    // MARK: Bandwidth readout (0x0E)

    /// Latest bandwidth packet, nil until the host starts sending them. A fresh
    /// connection means a fresh sender instance, so this never carries a previous
    /// host's numbers forward — see `PCVRBandwidthMonitor`, which depends on that.
    private(set) var bandwidth: ControllerBridgeBandwidth?
    private(set) var bandwidthReceivedAt: CFTimeInterval = 0

    /// Alignment tuning pushed to the host, resent periodically so a host restart or a
    /// transport swap re-adopts it without the user touching anything. Not persisted:
    /// it is a live diagnostic, not a per-title setting (see `ControllerBridgeDebugTune`).
    var debugTune = ControllerBridgeDebugTune() {
        didSet {
            guard debugTune != oldValue else { return }
            tuneDirty = true
        }
    }

    /// Bandwidth thresholds pushed to the host, resent periodically like `debugTune` so
    /// a host restart re-adopts them without the user re-entering anything.
    ///
    /// Unlike `debugTune`, this is NOT settable directly (see `updateBandwidthControl`).
    /// `debugTune`'s compiled-in default is neutral and safe to push on connect;
    /// `ControllerBridgeBandwidthControl()`'s default is `enabled: false`, and pushing
    /// that unconditionally on every reconnect — which the `debugTune` pattern does,
    /// since it resends on the very first tick regardless — would silently disable
    /// monitoring on the host every time someone reconnects. So until the user actually
    /// edits something, this mirrors whatever the host itself just reported (see the
    /// bandwidth decode branch below and `ingest(_ telemetry:)`'s identical trick for
    /// `debugTune.desktopQuad`), and only starts sending once `bandwidth != nil` — the
    /// host has been heard from at least once this session.
    private(set) var bandwidthControl = ControllerBridgeBandwidthControl() {
        didSet {
            guard bandwidthControl != oldValue else { return }
            bandwidthControlDirty = true
        }
    }
    private var bandwidthControlUserEdited = false

    /// Stage an edit from the PCVR tab's bandwidth panel. Latches out the host-mirroring
    /// above for the rest of the session — the headset is the only editor today.
    func updateBandwidthControl(enabled: Bool, warningThresholdGB: Float, stopThresholdGB: Float) {
        bandwidthControlUserEdited = true
        var control = bandwidthControl
        if enabled { control.flags.insert(.enabled) } else { control.flags.remove(.enabled) }
        control.warningThresholdGB = warningThresholdGB
        control.stopThresholdGB = stopThresholdGB
        bandwidthControl = control
    }

    /// The title the host says is reaching us, its profile, and where that came from.
    private(set) var activeGame: String?
    private(set) var gameProfile = GameProfile.empty
    private(set) var gameProfileSource: GameProfileSource = .global

    /// The gesture map in force: this title's override if it has one, else the global.
    var activeGestureMapping: GestureControllerMapping {
        gameProfile.input.gestureMapping ?? gestureMapping
    }

    /// Adopt a title's profile (on a game change, or when the settings UI edits one).
    func applyGameProfile(for game: String?) {
        let resolved = GameProfiles.resolve(for: game)
        gameProfile = resolved.profile
        gameProfileSource = resolved.source
    }

    /// Whether this title gets emulated controllers at all. Off means the 0x03 input
    /// packets stop entirely: a silent input stream is the protocol's own "no
    /// controllers" (the host must read stale input as disconnected, never as frozen),
    /// so within half a second the emulated pair unplugs and a game that tracks hands
    /// natively falls back to the skeletons we keep sending. Verified headset-less
    /// 2026-07-30: VDXR kept both hands live and moving with zero controllers present.
    var emulatesControllers: Bool {
        gameProfile.input.emulateControllers ?? true
    }

    /// Flip controller emulation for the active title, persisted in that title's saved
    /// profile so a game that plays best on native hands stays that way next launch.
    /// Turning it back on clears the override rather than storing `true`: the saved
    /// layer should only record what differs from the default, and `setSaved` removes
    /// an emptied profile outright.
    func setEmulateControllers(_ on: Bool) {
        var profile = gameProfile
        profile.input.emulateControllers = on ? nil : false
        GameProfiles.setSaved(profile, for: activeGame)
        applyGameProfile(for: activeGame)
    }
    private var tuneDirty = true
    private var tuneSequence: UInt8 = 0
    private var lastTuneSend: CFTimeInterval = 0
    private var pendingResolve = false
    private var pendingStopClient = false
    private var bandwidthControlDirty = true
    private var bandwidthControlSequence: UInt8 = 0
    private var lastBandwidthControlSend: CFTimeInterval = 0
    private var pendingBandwidthReset = false

    /// Ask the host to discard its solved alignment and re-converge from scratch.
    func requestAlignmentResolve() {
        pendingResolve = true
        tuneDirty = true
    }

    /// Ask the host to close the title currently submitting frames. Some OpenXR apps have
    /// no way out from inside the headset, and the alternative is taking the device off.
    func requestStopActiveClient() {
        pendingStopClient = true
        tuneDirty = true
    }

    /// Ask the host to zero its running monthly counter.
    func requestBandwidthReset() {
        pendingBandwidthReset = true
        bandwidthControlDirty = true
    }

    init(host: String) {
        self.host = host
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        control.onReady = { [weak self] endpoint in
            guard let self else { return }
            self.useDirectEndpoint(endpoint)
            self.onControlReady?(endpoint)
        }
        control.onPacket = { [weak self] packet in self?.ingestControlPacket(packet) }
        datagram.onSendError = { [weak self] message in
            Task { @MainActor in self?.lastSendError = message }
        }
        // Dev/testing path: a hand-configured bridge host gets a UDP endpoint before
        // any rendezvous. It only actually emits packets under the plaintext dev
        // opt-in (see BridgeDatagramChannel) — a real session waits for its keys.
        if !host.isEmpty {
            datagram.setEndpoint(host: host, port: ControllerBridgeProtocol.portInput)
        }
        // Re-adopt the persisted desk-Quest choice: the tune packet is latched and
        // resent, so a host restart mid-session picks it back up too.
        if UserDefaults.standard.bool(forKey: Self.questControllersDefaultsKey) {
            var tune = debugTune
            tune.flags.insert(.questControllers)
            debugTune = tune
        }
        startControllerWatch()
        spatialTracker.start()
        startHandTracking()
        startSendLoop()
        log.notice("ControllerBridge sender started → \(self.host, privacy: .public)")
    }

    // MARK: Physical controller lifecycle

    /// Adopt whatever is already connected and follow connect/disconnect from there.
    private func startControllerWatch() {
        let center = NotificationCenter.default
        controllerObservers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in self?.adopt(controller) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in self?.forget(controller) }
            },
        ]
        // Pick the best already-connected candidate. `extendedGamepad != nil` is the real
        // requirement — everything this sender reads lives on that profile — so filter on
        // it rather than trusting array order.
        if let existing = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            adopt(existing)
        }
    }

    private func adopt(_ candidate: GCController) {
        // Spatial controllers are per-hand devices with their own lifecycle; the
        // tracker owns them (they carry no extended gamepad profile anyway).
        guard candidate.productCategory != GCProductCategorySpatialController else { return }
        guard candidate.extendedGamepad != nil else {
            log.notice("Ignoring a controller with no extended gamepad profile.")
            return
        }
        // Prefer the one the system considers current, but never drop a working pad for a
        // device that cannot drive us.
        if let held = controller, held !== candidate, GCController.current === held { return }
        controller = candidate
        handDetector.reset()

        /* sensorsActive once, here, rather than every tick. Setting it at 83 Hz was not
           merely wasteful: it is a property that powers the IMU up, and re-asserting it
           continuously left no way to tell an absent sensor from a present one. Now the
           capability is read once and cached, so `motion == nil` is a real answer. */
        if let m = candidate.motion, m.hasRotationRate {
            m.sensorsActive = true
            motion = m
            log.notice("""
                Controller \(candidate.vendorName ?? "unknown", privacy: .public) attached \
                with motion (attitude: \(m.hasAttitude ? "yes" : "no", privacy: .public)).
                """)
        } else {
            motion = nil
            log.notice("""
                Controller \(candidate.vendorName ?? "unknown", privacy: .public) attached; \
                no rotation rate, so no IMU contribution.
                """)
        }
    }

    private func forget(_ leaving: GCController) {
        guard controller === leaving else { return }
        motion?.sensorsActive = false
        motion = nil
        controller = nil
        handDetector.reset()
        wristAngularSpeed.removeAll()
        lastWristRotation.removeAll()
        log.notice("Controller disconnected.")
        // Something else may still be plugged in.
        if let other = GCController.controllers().first(where: {
            $0 !== leaving && $0.extendedGamepad != nil
        }) {
            adopt(other)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sendTask?.cancel(); sendTask = nil
        handTask?.cancel(); handTask = nil
        datagram.stop()
        control.stop()
        channelReceiveTask?.cancel(); channelReceiveTask = nil
        messageChannel = nil
        adoptedToken = nil
        directHost = nil
        hapticEngines.values.forEach { $0.stop() }
        hapticEngines.removeAll()
        hapticPlayers.removeAll()
        hapticEngineOwners.removeAll()
        controllerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        controllerObservers.removeAll()
        spatialTracker.stop()
        // Leave the IMU powered down: a sender that has stopped has no use for it, and the
        // sensor costs the controller battery for as long as it is active.
        motion?.sensorsActive = false
        motion = nil
        controller = nil
        handDetector.reset()
        lastWristRotation.removeAll()
        wristAngularSpeed.removeAll()
        // Re-measured from the wearer's own hand on the next session; nothing here is
        // worth persisting across one, and a stale seed would just take longer to shed.
        anchorFromGrip.removeAll()
        gripConfidence.removeAll()
        // Nothing will sample the hand again, so no press is in progress.
        gestureCharge = nil
        joystickVisualization = nil
        log.notice("ControllerBridge sender stopped")
    }

    // MARK: Message channel (CloudXR opaque data channel)

    /// Switch to the session's message channel as the input transport. Haptic
    /// packets from the host layer arrive on the same channel's receive stream.
    func attach(channel: FoveatedStreamingSession.MessageChannel) {
        messageChannel = channel
        channelReceiveTask?.cancel()
        channelReceiveTask = Task { @MainActor [weak self] in
            for await message in channel.receivedMessageStream {
                guard !Task.isCancelled else { break }
                if let rendezvous = ControllerBridgeRendezvous(message) {
                    // The channel's whole job: hand over the token and the addresses.
                    // Adopting here rather than in the game library keeps the one thing
                    // that must happen for a session to work out of an optional feature.
                    self?.adopt(rendezvous: rendezvous)
                    self?.rendezvousHandler?(rendezvous)
                } else if let haptic = ControllerBridgeHaptic(message) {
                    self?.playHaptic(haptic)
                } else if let telemetry = ControllerBridgeTelemetry(message) {
                    self?.ingest(telemetry)
                }
            }
        }
        log.notice("ControllerBridge using message channel \(String(describing: channel.id), privacy: .public)")
        onChannelAttached?()
    }

    /// Drop a channel that is no longer available, so sends fall back to UDP (if
    /// configured) instead of going into a dead channel, and the library reports
    /// the host unreachable rather than silently losing every request.
    func detachChannel() {
        channelReceiveTask?.cancel()
        channelReceiveTask = nil
        messageChannel = nil
    }



    // MARK: Networking

    /* The legacy :9521 UDP return-path listener is gone. Host→client traffic rides
       the TCP control link (which has a peer by construction and cannot lose a bind
       race), with the message channel covering the pre-link bootstrap window. The
       listener was the source of a whole class of silent failures — NWListener does
       not throw for a port in use, so a lost race against a previous listener's
       asynchronous cancel() killed haptics, telemetry, perf and library replies for
       an entire session while input kept flowing. */

    /// One already-opened packet off the TCP control link — haptics, telemetry, perf.
    private func ingestControlPacket(_ payload: Data) {
        if let haptic = ControllerBridgeHaptic(payload) {
            playHaptic(haptic)
        } else if let telemetry = ControllerBridgeTelemetry(payload) {
            ingest(telemetry)
        } else if let perf = ControllerBridgePerf(payload) {
            ingest(perf)
        } else if let quest = ControllerBridgeQuestStatus(payload) {
            questStatus = quest
            questStatusReceivedAt = CACurrentMediaTime()
        } else if let bw = ControllerBridgeBandwidth(payload) {
            bandwidth = bw
            bandwidthReceivedAt = CACurrentMediaTime()
            // Keep mirroring the host's own state until the user actually edits
            // something — see `bandwidthControl`'s doc comment for why a blind
            // compiled-in default must never be the first thing sent back.
            if !bandwidthControlUserEdited {
                var control = bandwidthControl
                if bw.flags.contains(.enabled) { control.flags.insert(.enabled) }
                else { control.flags.remove(.enabled) }
                control.warningThresholdGB = bw.warningThresholdGB
                control.stopThresholdGB = bw.stopThresholdGB
                bandwidthControl = control
            }
        }
    }

    /// The host's desk-Quest feed (0x0D): present once a QuestControllerBridge headset
    /// has been heard from on the host's network, whatever the enable state. The HUD
    /// gates on `questStatusReceivedAt` so a dead feed reads as absent, not as stale
    /// good news.
    private(set) var questStatus: ControllerBridgeQuestStatus?
    private(set) var questStatusReceivedAt: CFTimeInterval = 0

    /// Whether we have told the host to consume the desk-Quest's controllers.
    var questControllersEnabled: Bool { debugTune.flags.contains(.questControllers) }

    /// Flip desk-Quest consumption. Persisted: the desk setup is physical and
    /// deliberate, so the choice survives sessions — but the flag itself still rides
    /// the sealed tune packet every time, which is what keeps consent with us.
    func setQuestControllers(_ on: Bool) {
        var tune = debugTune
        if on { tune.flags.insert(.questControllers) } else { tune.flags.remove(.questControllers) }
        debugTune = tune
        UserDefaults.standard.set(on, forKey: Self.questControllersDefaultsKey)
    }

    static let questControllersDefaultsKey = "foveatedQuestControllers"

    // MARK: The desktop panel

    /// Whether the host is showing your PC's screen on a panel in the home view.
    ///
    /// Read from the host's telemetry rather than from what we last asked for, because
    /// the desktop companion can turn it on and off too, and a button that reported only
    /// its own last press would sit there lying whenever the PC disagreed. Nil until the
    /// first telemetry arrives — the button has nothing truthful to show before then.
    var desktopQuadShown: Bool? {
        guard let telemetry else { return nil }
        return telemetry.flags.contains(.desktopQuad)
    }

    /// Whether the host is submitting frames with an alpha channel, so the parts a game
    /// (or the host's home scene) leaves transparent arrive as holes rather than as
    /// black. Owned entirely by the PC — the switch is in the Windows Companion, since
    /// the PC is what pays the encoder cost — and nil until the first telemetry, because
    /// guessing wrong means either a black portal or passthrough nobody asked for.
    var alphaBlendActive: Bool? {
        guard let telemetry else { return nil }
        return telemetry.flags.contains(.alphaBlend)
    }

    /// Show or hide the desktop panel. Takes effect immediately; the host answers in its
    /// next telemetry, which is what the button then reflects.
    func setDesktopQuad(_ on: Bool) {
        var tune = debugTune
        if on { tune.flags.insert(.desktopQuad) } else { tune.flags.remove(.desktopQuad) }
        guard tune.flags != debugTune.flags else { return }
        debugTune = tune
        tuneDirty = true
    }

    private func ingest(_ perf: ControllerBridgePerf) {
        self.perf = perf
        perfReceivedAt = CACurrentMediaTime()
        guard !perf.framePeriodsMs.isEmpty else { return }
        framePeriodHistory.append(contentsOf: perf.framePeriodsMs)
        let overflow = framePeriodHistory.count - Self.framePeriodHistoryLength
        if overflow > 0 { framePeriodHistory.removeFirst(overflow) }
    }

    private func ingest(_ telemetry: ControllerBridgeTelemetry) {
        let previousAlpha = self.telemetry?.flags.contains(.alphaBlend)
        self.telemetry = telemetry
        telemetryReceivedAt = CACurrentMediaTime()
        // Fires on the first packet too (`previousAlpha` is nil then): the space opens
        // before any telemetry arrives, so the first report is the one that decides
        // whether it was opened in the right style.
        let alpha = telemetry.flags.contains(.alphaBlend)
        if previousAlpha != alpha { onAlphaBlendChanged?(alpha) }
        // Follow the host on the desktop panel. The bit we send is latched, and the host
        // acts only when it changes; if the desktop companion turned the panel off, our
        // stale "on" would be the next change it saw and would turn it straight back on.
        let hostShowingDesktop = telemetry.flags.contains(.desktopQuad)
        if debugTune.flags.contains(.desktopQuad) != hostShowingDesktop {
            var tune = debugTune
            if hostShowingDesktop { tune.flags.insert(.desktopQuad) }
            else { tune.flags.remove(.desktopQuad) }
            debugTune = tune
        }
        // Switching titles switches profiles: what a game expects from the emulated
        // controller is a property of that game, so carrying one title's input mapping
        // into the next would be worse than falling back to the globals.
        if telemetry.activeClient != activeGame {
            activeGame = telemetry.activeClient
            applyGameProfile(for: activeGame)
            log.notice("""
                Profile for \(self.activeGame ?? "no title", privacy: .public): \
                \(self.gameProfileSource.rawValue, privacy: .public)
                """)
        }
    }

    private func playHaptic(_ haptic: ControllerBridgeHaptic) {
        let amplitude = min(max(haptic.amplitude, 0), 1)
        if amplitude == 0 {
            if let player = hapticPlayers.removeValue(forKey: haptic.controller) {
                try? player.stop(atTime: CHHapticTimeImmediate)
            }
            return
        }

        // The device actually occupying the pulsed hand: a spatial controller of that
        // chirality if one is connected, else the adopted gamepad — not whatever the
        // framework lists first; rumbling a different device than the one in the
        // user's hands was the same bug the input path had.
        let side: BridgeHand = haptic.controller == 0 ? .left : .right
        guard let target = spatialTracker.controllers[side] ?? controller,
              let deviceHaptics = target.haptics else { return }

        // Games spam short pulses at frame rate; per-side coalescing keeps us from
        // stacking a CoreHaptics player per packet.
        let now = CACurrentMediaTime()
        if now - (lastHapticTime[haptic.controller] ?? 0) < 0.010 { return }
        lastHapticTime[haptic.controller] = now

        // Cached engines belong to one specific device; rebuild this side's on swap.
        if hapticEngineOwners[haptic.controller] != ObjectIdentifier(target) {
            if let player = hapticPlayers.removeValue(forKey: haptic.controller) {
                try? player.stop(atTime: CHHapticTimeImmediate)
            }
            hapticEngines[haptic.controller]?.stop()
            hapticEngines[haptic.controller] = nil
            hapticEngineOwners[haptic.controller] = ObjectIdentifier(target)
        }

        let engine: CHHapticEngine
        if let cached = hapticEngines[haptic.controller] {
            engine = cached
        } else {
            let wanted: GCHapticsLocality = haptic.controller == 0 ? .leftHandle : .rightHandle
            let locality = deviceHaptics.supportedLocalities.contains(wanted) ? wanted : .default
            guard let created = deviceHaptics.createEngine(withLocality: locality) else {
                log.notice("No haptic engine for locality \(locality.rawValue, privacy: .public)")
                return
            }
            // On reset/stop, drop the cache so the next pulse recreates cleanly.
            let side = haptic.controller
            created.resetHandler = { [weak self] in
                Task { @MainActor in
                    self?.hapticPlayers[side] = nil
                    self?.hapticEngines[side] = nil
                }
            }
            created.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.hapticPlayers[side] = nil
                    self?.hapticEngines[side] = nil
                }
            }
            do { try created.start() } catch {
                log.error("Haptic engine start failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            hapticEngines[haptic.controller] = created
            engine = created
        }

        // Index-controller haptics run ~1–320 Hz; map frequency onto sharpness.
        let intensity = CHHapticEventParameter(
            parameterID: .hapticIntensity, value: amplitude)
        let sharpness = CHHapticEventParameter(
            parameterID: .hapticSharpness, value: min(max(haptic.frequency / 320, 0), 1))
        // SteamVR sends duration 0 for click-style pulses → transient event.
        let event = haptic.duration > 0
            ? CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness],
                            relativeTime: 0, duration: Double(min(haptic.duration, 2)))
            : CHHapticEvent(eventType: .hapticTransient, parameters: [intensity, sharpness],
                            relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            if let player = hapticPlayers.removeValue(forKey: haptic.controller) {
                try? player.stop(atTime: CHHapticTimeImmediate)
            }
            let player = try engine.makePlayer(with: pattern)
            hapticPlayers[haptic.controller] = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log.debug("Haptic play failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: ARKit hand tracking

    private func startHandTracking() {
        guard HandTrackingProvider.isSupported else {
            log.notice("Hand tracking unsupported on this device/context.")
            return
        }
        handTask = Task { @MainActor in
            let auth = await arSession.requestAuthorization(for: [.handTracking])
            guard auth[.handTracking] == .allowed else {
                log.notice("Hand-tracking authorization denied.")
                return
            }
            do {
                // World tracking supplies the head pose for the locomotion joystick's
                // head-relative basis; it needs no separate authorization prompt.
                try await arSession.run([handProvider, worldProvider])
            } catch {
                log.error("ARKit run failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            for await update in handProvider.anchorUpdates {
                if Task.isCancelled { break }
                ingest(update.anchor)
            }
        }
    }

    private func ingest(_ anchor: HandAnchor) {
        // Feed the gesture engine first (it tracks per-finger pinches + the joystick).
        gestureEngine.ingest(anchor)

        let hand: BridgeHand = anchor.chirality == .left ? .left : .right
        guard anchor.isTracked else {
            if hand == .left { leftHand = nil; leftJoints = nil }
            else { rightHand = nil; rightJoints = nil }
            gripConfidence[hand] = nil
            // An untracked wrist has no speed to report. Clearing rather than holding the
            // last value matters: a stale speed would keep "agreeing" with the controller
            // through a dropout and could win the hand it is no longer describing.
            wristAngularSpeed[hand] = nil
            lastWristRotation[hand] = nil
            return
        }
        // Send the OpenXR *grip* pose, not the raw anchor. A HandAnchor's origin is the
        // wrist, but games mount weapons and held objects on the grip pose, which OpenXR
        // defines at the palm centroid — so shipping the wrist made everything hang ~8 cm
        // too far back, rooted in the wrist. Falls back to the anchor when the skeleton
        // is unavailable.
        let pose = gripPose(from: anchor) ?? Self.rawPose(from: anchor.originFromAnchorTransform)
        let joints = Self.skeletonJoints(from: anchor)
        if hand == .left { leftHand = pose; leftJoints = joints }
        else { rightHand = pose; rightJoints = joints }
        gripConfidence[hand] = Self.gripConfidence(for: anchor)

        /* This wrist's angular speed, for the hand-holding-the-controller decision. Derived
           from the grip pose we are already sending rather than a second source, so what is
           compared against the IMU is the same rotation the host will be given. */
        let now = CACurrentMediaTime()
        if let previous = lastWristRotation[hand] {
            wristAngularSpeed[hand] = ControllerHandDetector.angularSpeed(
                from: previous.rotation, to: pose.orientation, dt: now - previous.at)
        }
        lastWristRotation[hand] = (pose.orientation, now)
    }

    private static func rawPose(from t: simd_float4x4) -> ControllerBridgeHandPose {
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let rot = simd_quatf(simd_float3x3(
            SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
            SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
            SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        ))
        return ControllerBridgeHandPose(position: pos, orientation: rot, gyro: .zero)
    }

    /// The OpenXR grip pose, built from joint *positions* only — so it never depends on
    /// ARKit's per-joint axis conventions, and it scales to the actual user's hand instead
    /// of a measured-once offset.
    ///
    /// Position: mid-palm, halfway from the wrist to the middle-finger knuckle — where a
    /// controller handle would sit inside a closed fist.
    ///
    /// Orientation, per the OpenXR "grip" convention:
    ///   −Z  through the tube formed by the curled non-thumb fingers, little → thumb
    ///   +X  the palm normal
    ///   +Y  completes the right-handed basis
    /// Both chiralities use the same construction: OpenXR grip frames are deliberately
    /// *not* mirrored, which is the whole point of having a shared convention.
    ///
    /// The construction is a *measurement*, not the published pose. Every joint it reads
    /// except the wrist is a finger joint, and a thumb-to-index pinch adducts the index
    /// knuckle and cups the palm — so building the pose live meant the grip rotated and
    /// shifted whenever the fingers moved, and the pinch mapped to the trigger, so pressing
    /// the trigger visibly moved the hand in-game. A controller's grip pose is rigid to the
    /// hand; it cannot depend on what the fingers are doing. So the measurement is reduced
    /// to a rigid `anchorFromGrip` offset, refreshed only while the hand is relaxed and then
    /// carried by the hand anchor — which ARKit places at the wrist and never articulates.
    private func gripPose(from anchor: HandAnchor) -> ControllerBridgeHandPose? {
        guard let skeleton = anchor.handSkeleton else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func jointWorld(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let wrist = jointWorld(.wrist)
        let middleKnuckle = jointWorld(.middleFingerKnuckle)
        let indexKnuckle = jointWorld(.indexFingerKnuckle)
        let littleKnuckle = jointWorld(.littleFingerKnuckle)

        // distal: wrist → fingers, along the palm. across: little → index, i.e. thumb-ward.
        let distal = middleKnuckle - wrist
        let across = indexKnuckle - littleKnuckle
        guard simd_length(distal) > 1e-5, simd_length(across) > 1e-5 else { return nil }
        let d = simd_normalize(distal)
        let a = simd_normalize(across)

        // x ⟂ a by construction, so z = -a is already orthogonal to it and y follows.
        let xAxis = simd_cross(d, a)
        guard simd_length(xAxis) > 1e-5 else { return nil }   // degenerate: d ∥ a
        let x = simd_normalize(xAxis)
        let z = -a
        let y = simd_cross(z, x)

        let hand: BridgeHand = anchor.chirality == .left ? .left : .right
        let measured = (position: (wrist + middleKnuckle) * 0.5,
                        orientation: simd_quatf(simd_float3x3(x, y, z)) * Self.fistFromFlatHand)
        let anchorPose = Self.rawPose(from: originFromAnchor)

        // Seed on the first tracked frame so the pose is rigid immediately — a hand that
        // happens to arrive mid-pinch is corrected as soon as it relaxes — then refine
        // slowly, and never while a pinch is deforming the palm.
        if anchorFromGrip[hand] == nil || Self.handIsRelaxed(skeleton: skeleton,
                                                            originFromAnchor: originFromAnchor) {
            let inverse = anchorPose.orientation.inverse
            let offset = (rotation: simd_normalize(inverse * measured.orientation),
                          position: inverse.act(measured.position - anchorPose.position))
            if let previous = anchorFromGrip[hand] {
                // Slow enough that a mis-measured frame cannot show up as a twitch, fast
                // enough to converge within a second or so of relaxed tracking.
                anchorFromGrip[hand] = (
                    rotation: simd_normalize(simd_slerp(previous.rotation, offset.rotation, 0.05)),
                    position: simd_mix(previous.position, offset.position, SIMD3(repeating: 0.05)))
            } else {
                anchorFromGrip[hand] = offset
            }
        }
        guard let offset = anchorFromGrip[hand] else { return nil }
        return ControllerBridgeHandPose(
            position: anchorPose.position + anchorPose.orientation.act(offset.position),
            orientation: simd_normalize(anchorPose.orientation * offset.rotation),
            gyro: .zero)
    }

    /// The angle between the frame the knuckles describe and the frame a controller
    /// actually sits in, about the palm normal.
    ///
    /// The construction above reads knuckle geometry, which is the same whether the hand is
    /// open or closed, so what it measures is a *flat* hand. OpenXR's grip pose is defined
    /// for a hand curled around a handle, and closing the fist swings the barrel toward the
    /// wrist — so a game mounting its hand model on the grip drew it rotated, which on a
    /// hand held palm-sideways (how you hold a controller) reads as tilted up.
    ///
    /// −20° found on device in Hyperbolica via the layer's `GripFromWrist` registry override
    /// ("0 0 0 -20 0 0"), then moved here: the override is applied by the API layer only,
    /// while the broker publishes the packet pose to VDXR unconverted, so leaving it there
    /// left the two paths disagreeing by exactly this rotation — and the host's solve-miss
    /// readout, which compares them, inheriting it as a permanent 20° floor.
    private static let fistFromFlatHand = simd_quatf(angle: -20 * .pi / 180, axis: [1, 0, 0])

    /// How much of this hand ARKit is actually SEEING, 1–255, scored over the joints the
    /// grip pose is built from (wrist + index/middle/little knuckles). ARKit keeps
    /// reporting positions for occluded joints — inferred from a learned hand model — and
    /// flags the difference per joint via `isTracked`. A hand wrapped around a controller
    /// is always partly occluded, which is exactly why this ships as a weight and not a
    /// gate: the host must be able to trust clean frames more without ever starving on
    /// mediocre ones. Floored at 1 so a real report is never mistaken for the wire's
    /// "not reported" zero.
    private static func gripConfidence(for anchor: HandAnchor) -> UInt8 {
        guard let skeleton = anchor.handSkeleton else { return 128 }
        let basis: [HandSkeleton.JointName] = [.wrist, .indexFingerKnuckle,
                                               .middleFingerKnuckle, .littleFingerKnuckle]
        let tracked = basis.count { skeleton.joint($0).isTracked }
        return UInt8(max(1, tracked * 255 / basis.count))
    }

    /// Whether the palm is open enough to re-measure the grip offset from it. The test is
    /// local geometry rather than the gesture engine's verdict on purpose: the engine
    /// suppresses pinches per hand while the wrist HUD is up, and a suppressed pinch still
    /// deforms the palm exactly the same way.
    private static func handIsRelaxed(skeleton: HandSkeleton,
                                      originFromAnchor: simd_float4x4) -> Bool {
        func jointWorld(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        // Comfortably past HandGestureEngine's 4.5 cm release distance, so the offset is
        // never re-measured on a hand that is on its way into or out of a pinch.
        let clearance: Float = 0.07
        let thumbTip = jointWorld(.thumbTip)
        for tip in [HandSkeleton.JointName.indexFingerTip, .middleFingerTip,
                    .ringFingerTip, .littleFingerTip] {
            if simd_distance(jointWorld(tip), thumbTip) < clearance { return false }
        }
        return true
    }

    /// The full 26-joint XR_EXT skeleton in headset world space. Orientations are built
    /// from joint POSITIONS only (bone direction + a dorsal reference), the same
    /// convention-proof construction as `gripPose(from:)`, so nothing here depends on
    /// ARKit's per-joint axis conventions. XR_EXT frames: -Z along the bone toward the
    /// fingertip, +Y out of the back of the hand, both chiralities un-mirrored.
    private static func skeletonJoints(from anchor: HandAnchor) -> [ControllerBridgeJoint]? {
        guard let skeleton = anchor.handSkeleton else { return nil }
        let originFromAnchor = anchor.originFromAnchorTransform
        func p(_ joint: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = originFromAnchor * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let wrist = p(.wrist)
        let middleKnuckle = p(.middleFingerKnuckle)
        let distal = middleKnuckle - wrist
        let across = p(.indexFingerKnuckle) - p(.littleFingerKnuckle)   // little → index
        guard simd_length(distal) > 1e-5, simd_length(across) > 1e-5 else { return nil }
        let d = simd_normalize(distal)
        let raw = simd_cross(d, simd_normalize(across))
        guard simd_length(raw) > 1e-5 else { return nil }
        // cross(distal, thumb-ward) points out of the BACK of the right hand and out of
        // the PALM of the left (worked out from palm-down geometry); flip to dorsal.
        let dorsal = anchor.chirality == .right ? simd_normalize(raw) : -simd_normalize(raw)

        func joint(_ pos: SIMD3<Float>, boneDir: SIMD3<Float>, radius: Float) -> ControllerBridgeJoint {
            var z = -boneDir
            let zLen = simd_length(z)
            z = zLen > 1e-5 ? z / zLen : -d
            var y = dorsal - z * simd_dot(dorsal, z)
            let yLen = simd_length(y)
            // Degenerate (bone ∥ dorsal, thumb can get close): fall back to the palm
            // distal direction as the up reference.
            y = yLen > 1e-4 ? y / yLen : simd_normalize(d - z * simd_dot(d, z))
            let x = simd_cross(y, z)
            return ControllerBridgeJoint(position: pos,
                                         orientation: simd_quatf(simd_float3x3(x, y, z)),
                                         radius: radius)
        }

        /// One finger chain: bone direction at each joint points at the next joint;
        /// the tip reuses the last bone's direction.
        func chain(_ names: [HandSkeleton.JointName], _ radii: [Float],
                   into out: inout [ControllerBridgeJoint]) {
            let positions = names.map { p($0) }
            for i in 0..<positions.count {
                let dir = i + 1 < positions.count
                    ? positions[i + 1] - positions[i]
                    : positions[i] - positions[i - 1]
                out.append(joint(positions[i], boneDir: dir, radius: radii[i]))
            }
        }

        var joints: [ControllerBridgeJoint] = []
        joints.reserveCapacity(ControllerBridgeProtocol.handJointCount)
        joints.append(joint((wrist + middleKnuckle) * 0.5, boneDir: d, radius: 0.025))  // 0 palm
        joints.append(joint(wrist, boneDir: d, radius: 0.021))                          // 1 wrist
        chain([.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
              [0.013, 0.011, 0.009, 0.008], into: &joints)                              // 2-5
        chain([.indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase,
               .indexFingerIntermediateTip, .indexFingerTip],
              [0.014, 0.011, 0.009, 0.008, 0.007], into: &joints)                       // 6-10
        chain([.middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase,
               .middleFingerIntermediateTip, .middleFingerTip],
              [0.014, 0.011, 0.009, 0.008, 0.007], into: &joints)                       // 11-15
        chain([.ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase,
               .ringFingerIntermediateTip, .ringFingerTip],
              [0.014, 0.011, 0.009, 0.008, 0.007], into: &joints)                       // 16-20
        chain([.littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
               .littleFingerIntermediateTip, .littleFingerTip],
              [0.013, 0.010, 0.008, 0.007, 0.006], into: &joints)                       // 21-25
        assert(joints.count == ControllerBridgeProtocol.handJointCount)
        return joints
    }

    // MARK: Send loop

    private func startSendLoop() {
        sendTask = Task { @MainActor in
            /* Absolute deadlines, not a fixed sleep after the work: `Task.sleep(for:)`
               accumulates the loop body's own cost plus scheduling latency into the
               period, so the "83 Hz" loop sagged under main-actor load exactly when
               the app was busiest. Deadlines drift-compensate; a late tick shortens
               the next sleep instead of shifting every tick after it. */
            let clock = ContinuousClock()
            let period = Duration.milliseconds(12)   // ~83 Hz
            var deadline = clock.now
            while !Task.isCancelled && isRunning {
                if emulatesControllers {
                    send(buildPacket().encoded())
                } else {
                    // Hands-only: no 0x03 at all — absence is the off switch, so an
                    // old host needs no new flag to get it right. Skeletons and the
                    // head keep flowing below; they are what native hand tracking
                    // runs on. No packet means no pinch can be mid-press either.
                    sequence &+= 1
                    gestureCharge = nil
                    joystickVisualization = nil
                }
                // Our ARKit head pose rides along at input rate: the host aligns the
                // hand packets' ARKit world origin to the streaming runtime's tracking
                // origin by comparing this against its own view of the same head.
                if worldProvider.state == .running,
                   let device = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
                    let m = device.originFromAnchorTransform
                    var headPacket = ControllerBridgeHeadPose()
                    headPacket.sequence = sequence
                    headPacket.position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                    headPacket.orientation = simd_quatf(simd_float3x3(
                        SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                        SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                        SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
                    send(headPacket.encoded())
                }
                // Skeletons alternate with input packets (~42 Hz per hand) — a full
                // game frame of finger motion is imperceptible, and it halves the
                // channel load. Each tracked hand ships as its own 836-byte 0x05
                // packet: the channel drops the 1668-byte both-hands form.
                sendJointsThisTick.toggle()
                if sendJointsThisTick {
                    for (hand, joints) in [(UInt8(0), leftJoints), (UInt8(1), rightJoints)] {
                        guard let joints else { continue }
                        jointsSequence &+= 1
                        send(ControllerBridgeHandJointsOne(
                            sequence: jointsSequence, hand: hand, joints: joints).encoded())
                    }
                }
                sendDebugTuneIfNeeded()
                sendBandwidthControlIfNeeded()
                deadline += period
                let now = clock.now
                // Fell more than a period behind (a long main-actor stall): re-anchor
                // rather than bursting packets to "catch up" — latest-wins state has
                // nothing to gain from a backlog replay.
                if deadline < now { deadline = now + period }
                try? await clock.sleep(until: deadline)
            }
        }
    }

    /// Push the alignment tuning: immediately when the HUD changes it, and every 200 ms
    /// regardless so a host that restarted mid-session picks the values back up.
    private func sendDebugTuneIfNeeded() {
        let now = CACurrentMediaTime()
        guard tuneDirty || now - lastTuneSend > 0.2 else { return }
        var tune = debugTune
        if pendingResolve { tune.flags.insert(.resolve) }
        if pendingStopClient { tune.flags.insert(.stopClient) }
        tuneSequence &+= 1
        // Tuning is a command, not a pose: it goes on the ordered link, and only falls
        // back to the input datagram path when there is no control link yet.
        let encoded = tune.encoded(sequence: tuneSequence)
        if !control.send(encoded) { send(encoded) }
        // One shot: these are events, and every resend carries a new sequence — a latched
        // flag would re-fire them a few times a second.
        pendingResolve = false
        pendingStopClient = false
        tuneDirty = false
        lastTuneSend = now
    }

    /// Push bandwidth thresholds: immediately when the panel changes them, and every
    /// 200 ms regardless so a host restart mid-session picks the values back up —
    /// same cadence and reasoning as `sendDebugTuneIfNeeded`. Sends nothing at all
    /// until the host has been heard from this session (`bandwidth != nil`) — before
    /// that, `bandwidthControl` is still the compiled-in default, and sending it would
    /// be exactly the "reconnect silently disables monitoring" bug this whole
    /// mirror-until-edited scheme exists to avoid.
    private func sendBandwidthControlIfNeeded() {
        guard bandwidth != nil else { return }
        let now = CACurrentMediaTime()
        guard bandwidthControlDirty || now - lastBandwidthControlSend > 0.2 else { return }
        var outgoing = bandwidthControl
        if pendingBandwidthReset { outgoing.flags.insert(.reset) }
        bandwidthControlSequence &+= 1
        let encoded = outgoing.encoded(sequence: bandwidthControlSequence)
        if !control.send(encoded) { send(encoded) }
        pendingBandwidthReset = false
        bandwidthControlDirty = false
        lastBandwidthControlSend = now
    }

    private func buildPacket() -> ControllerBridgeInputState {
        var state = ControllerBridgeInputState()
        sequence &+= 1
        state.sequence = sequence

        var flags: ControllerBridgeProtocol.Flags = []
        if let left = leftHand {
            state.left = left
            flags.insert(.leftHandTracked)
            state.leftConfidence = gripConfidence[.left] ?? 128
        }
        if let right = rightHand {
            state.right = right
            flags.insert(.rightHandTracked)
            state.rightConfidence = gripConfidence[.right] ?? 128
        }

        /* Spatial controllers: a tracked accessory pose replaces the wrist-derived
           pose for its hand. It is rigid to the physical controller (no finger-motion
           coupling, no grip-offset estimation) and carries its own gyro, so both the
           pose and the per-hand gyro attribution are simply *known* for that side —
           the Switch Pro IMU dance below skips any hand claimed here. An untracked or
           stale accessory ages out in trackedPose() and the wrist pose (already set
           above) carries the hand through the dropout. */
        let spatialNow = CACurrentMediaTime()
        var spatialClaims: (left: Bool, right: Bool) = (false, false)
        if let pose = spatialTracker.trackedPose(for: .left, now: spatialNow) {
            state.left = pose
            state.leftConfidence = 255
            flags.insert(.leftHandTracked)
            flags.insert(.leftGyroValid)
            flags.insert(.gyroValid)
            spatialClaims.left = true
        }
        if let pose = spatialTracker.trackedPose(for: .right, now: spatialNow) {
            state.right = pose
            state.rightConfidence = 255
            flags.insert(.rightHandTracked)
            flags.insert(.rightGyroValid)
            flags.insert(.gyroValid)
            spatialClaims.right = true
        }

        // Hand-gesture controller emulation. Held pinches → buttons/triggers, left
        // thumb+index → the locomotion stick. Applied first so a physical controller
        // (below) augments rather than is masked by it.
        let (forward, right) = headBasis()
        let gestures = gestureEngine.poll(worldForward: forward, worldRight: right)
        let mapping = activeGestureMapping
        var charge: GestureCharge?
        if let finger = gestures.left.held {
            flags.insert(.leftPinch)
            apply(mapping.target(for: .left, finger: finger), hand: .left,
                  heldFor: gestures.left.heldDuration, charge: &charge, to: &state)
        }
        if let finger = gestures.right.held {
            flags.insert(.rightPinch)
            apply(mapping.target(for: .right, finger: finger), hand: .right,
                  heldFor: gestures.right.heldDuration, charge: &charge, to: &state)
        }
        gestureCharge = charge
        state.leftStick = gestures.joystick.vector
        joystickVisualization = gestures.joystick.visualization

        if let pad = controller?.extendedGamepad {
            flags.insert(.controllerPresent)
            applyGamepad(pad, to: &state)
        }
        for hand in [BridgeHand.left, .right] {
            if let spatial = spatialTracker.controllers[hand] {
                flags.insert(.controllerPresent)
                applySpatialController(spatial, hand: hand, to: &state)
            }
        }
        if let motion {
            let rr = motion.rotationRate
            let gyro = SIMD3<Float>(Float(rr.x), Float(rr.y), Float(rr.z))
            /* Decide whose motion this is before shipping it. The detector wants the
               controller's angular SPEED, which is the magnitude of that rate — see
               ControllerHandAssignment for why speed rather than axes. */
            let holder = resolveHolder(controllerSpeed: simd_length(gyro))
            // A hand a spatial controller claimed keeps that controller's own gyro —
            // the gamepad IMU can only be describing some *other* hand (or a desk).
            if holder.claimsLeft && !spatialClaims.left {
                state.left.gyro = gyro
                flags.insert(.leftGyroValid)
            }
            if holder.claimsRight && !spatialClaims.right {
                state.right.gyro = gyro
                flags.insert(.rightGyroValid)
            }
            // The summary bit is the union, never set alone — a host testing only it and
            // then reading both hands would get a zero gyro on the unclaimed one, which is
            // exactly what the per-hand bits exist to prevent.
            if holder != .unknown { flags.insert(.gyroValid) }
        }
        state.flags = flags
        return state
    }

    /// The holder for this tick: the user's override, or the detector fed with this tick's
    /// speeds. Called once per packet so the detector's window advances at the send rate.
    private func resolveHolder(controllerSpeed: Float) -> ControllerHolder {
        if let forced = handPreference.forced { return forced }
        return handDetector.update(controllerSpeed: controllerSpeed,
                                   leftWristSpeed: wristAngularSpeed[.left],
                                   rightWristSpeed: wristAngularSpeed[.right],
                                   now: CACurrentMediaTime())
    }

    /// Map a normalized extended gamepad (the Switch Pro is reported in Xbox-
    /// equivalent positions by GameController) to the Switch Pro button set the
    /// driver splits left/right.
    private func applyGamepad(_ pad: GCExtendedGamepad, to state: inout ControllerBridgeInputState) {
        var buttons: ControllerBridgeProtocol.Buttons = []
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonB.isPressed { buttons.insert(.b) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonY.isPressed { buttons.insert(.y) }
        if pad.leftShoulder.isPressed { buttons.insert(.l) }
        if pad.rightShoulder.isPressed { buttons.insert(.r) }
        if pad.leftTrigger.isPressed { buttons.insert(.zl) }
        if pad.rightTrigger.isPressed { buttons.insert(.zr) }
        if pad.dpad.up.isPressed { buttons.insert(.dpadUp) }
        if pad.dpad.down.isPressed { buttons.insert(.dpadDown) }
        if pad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { buttons.insert(.dpadRight) }
        if pad.leftThumbstickButton?.isPressed == true { buttons.insert(.lstick) }
        if pad.rightThumbstickButton?.isPressed == true { buttons.insert(.rstick) }
        if pad.buttonMenu.isPressed { buttons.insert(.plus) }
        if pad.buttonOptions?.isPressed == true { buttons.insert(.minus) }
        if pad.buttonHome?.isPressed == true { buttons.insert(.home) }

        // Merge with any gesture-driven input rather than overwriting it.
        state.buttons.formUnion(buttons)
        // The pad's left stick takes over locomotion only when actually deflected;
        // otherwise the gesture joystick (set earlier) stands.
        let padLeft = SIMD2<Float>(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
        if simd_length(padLeft) > 0.15 { state.leftStick = padLeft }
        state.rightStick = SIMD2<Float>(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        state.leftTrigger = max(state.leftTrigger, pad.leftTrigger.value)
        state.rightTrigger = max(state.rightTrigger, pad.rightTrigger.value)
    }

    /// Map one spatial controller (a single-hand device, read through the live-input
    /// element API — these are not extended gamepads) onto its side of the protocol's
    /// Switch-Pro-shaped button set, mirroring the split controller_synth.h applies:
    /// right = A/B + ZR/R + right stick + PLUS, left = X/Y + ZL/L + left stick + MINUS.
    /// Merges like the gamepad path: union with gestures, max on triggers, deflection
    /// wins on sticks.
    private func applySpatialController(_ controller: GCController, hand: BridgeHand,
                                        to state: inout ControllerBridgeInputState) {
        let input = controller.input
        func pressed(_ name: GCButtonElementName) -> Bool {
            input.buttons[name]?.pressedInput.isPressed == true
        }
        var buttons: ControllerBridgeProtocol.Buttons = []
        let trigger = input.buttons[.trigger]?.pressedInput.value ?? 0
        let stick: SIMD2<Float> = input.dpads[.thumbstick].map {
            SIMD2($0.xyAxes.value.x, $0.xyAxes.value.y)
        } ?? .zero
        if hand == .right {
            // On the right Sense, `.a`/`.b` are Cross/Circle — the positions Touch
            // bindings expect as a/b.
            if pressed(.a) { buttons.insert(.a) }
            if pressed(.b) { buttons.insert(.b) }
            if pressed(.grip) { buttons.insert(.r) }
            if pressed(.thumbstickButton) { buttons.insert(.rstick) }
            if pressed(.menu) { buttons.insert(.plus) }
            if trigger > 0.75 { buttons.insert(.zr) }
            state.rightTrigger = max(state.rightTrigger, trigger)
            if simd_length(stick) > 0.15 { state.rightStick = stick }
        } else {
            // On the left Sense the same element names are Square/Triangle — the
            // left-hand x/y positions.
            if pressed(.a) { buttons.insert(.x) }
            if pressed(.b) { buttons.insert(.y) }
            if pressed(.grip) { buttons.insert(.l) }
            if pressed(.thumbstickButton) { buttons.insert(.lstick) }
            if pressed(.menu) { buttons.insert(.minus) }
            if trigger > 0.75 { buttons.insert(.zl) }
            state.leftTrigger = max(state.leftTrigger, trigger)
            if simd_length(stick) > 0.15 { state.leftStick = stick }
        }
        state.buttons.formUnion(buttons)
    }

    /// How long menu / system must be held before they are sent. See `GestureCharge`.
    static let chargeDuration: TimeInterval = 1.5

    /// A menu-class gesture being held, and how far through its hold it is (0…1). The
    /// immersive view draws this as a filling ring at the hand so the press is visible
    /// while it charges and can be abandoned by opening the hand.
    struct GestureCharge: Equatable {
        var hand: BridgeHand
        var target: BridgeGestureTarget
        /// Quantised to `chargeSteps`, so holding one down redraws the attachment a dozen
        /// times rather than once per send tick. A `ViewAttachmentComponent`'s root view is
        /// re-rasterised on every change, and the wrist HUD already limits itself to 10 Hz
        /// for the same reason; a continuously-changing value here would put SwiftUI layout
        /// on the main actor at the send rate, competing with the stream for it.
        var progress: Float
    }

    /// Set while a menu-class gesture is charging; nil the instant it fires or releases.
    private(set) var gestureCharge: GestureCharge? {
        didSet { if gestureCharge != nil { gestureChargeAt = CACurrentMediaTime() } }
    }
    /// When the charge was last written. The ring is drawn from a published value, so if
    /// the send loop ever stops the last value would otherwise sit there for good — which
    /// is exactly what happened when a session drop left the bridge stopped: a ring frozen
    /// part-filled, apparently ignoring the hand. A press that is not being sampled must
    /// not be drawn.
    private(set) var gestureChargeAt: CFTimeInterval = 0

    /// Renderer-neutral geometry for the locomotion joystick (see `RAVEJoystickVisualization`),
    /// nil while the joystick pinch is not held. The immersive view draws this at the wrist
    /// anchor as a disc + handle, same freshness discipline as `gestureCharge` above: a
    /// stopped send loop must not leave a stick frozen mid-deflection.
    private(set) var joystickVisualization: RAVEJoystickVisualization? {
        didSet { if joystickVisualization != nil { joystickVisualizationAt = CACurrentMediaTime() } }
    }
    /// When the joystick visualization was last written.
    private(set) var joystickVisualizationAt: CFTimeInterval = 0

    /// Steps in the charge ring: ~10 per second of hold.
    static let chargeSteps: Float = 15

    /// Resolve a gesture target to packet fields. Side-dependent targets (trigger /
    /// grip / stick-click) use the pinching hand; face buttons / menu / system are
    /// absolute. The host splits the button mask across the two emulated controllers.
    ///
    /// Menu and system are the two targets that can end a session outright — hello_xr
    /// binds menu straight to `xrRequestExitSession`, and it took a while to work out
    /// that a title quitting itself 15 s in was us, not the frame path. They also sit on
    /// the little finger by default, the one that curls on its own as a hand relaxes. So
    /// they alone need a deliberate hold, reported through `charge` so the user can watch
    /// it fill and let go if they did not mean it.
    private func apply(_ target: BridgeGestureTarget, hand: BridgeHand,
                       heldFor: TimeInterval, charge: inout GestureCharge?,
                       to state: inout ControllerBridgeInputState) {
        switch target {
        case .none: break
        case .trigger:
            if hand == .left { state.leftTrigger = 1; state.buttons.insert(.zl) }
            else { state.rightTrigger = 1; state.buttons.insert(.zr) }
        case .grip:       state.buttons.insert(hand == .left ? .l : .r)
        case .stickClick: state.buttons.insert(hand == .left ? .lstick : .rstick)
        case .aButton:    state.buttons.insert(.a)
        case .bButton:    state.buttons.insert(.b)
        case .xButton:    state.buttons.insert(.x)
        case .yButton:    state.buttons.insert(.y)
        case .menu, .system:
            let full = Self.chargeDuration
            if heldFor >= full {
                state.buttons.insert(target == .menu ? .plus : .home)
            } else {
                let fraction = Float(max(0, heldFor) / full)
                charge = GestureCharge(
                    hand: hand, target: target,
                    progress: (fraction * Self.chargeSteps).rounded(.down) / Self.chargeSteps)
            }
        }
    }

    /// Head-relative XZ basis (forward, right) for the locomotion joystick, from the
    /// world-tracking device anchor. Falls back to world axes if unavailable.
    // MARK: Wrist HUD support
    //
    // The HUD is drawn by FoveatedImmersiveView but posed from here, because the hand
    // anchors already flow through this object and a second HandTrackingProvider would
    // be a second ARKit consumer competing for the same data.

    /// Head position in the same ARKit world space the hand anchors report in, or nil
    /// while world tracking isn't running.
    var headWorldPosition: SIMD3<Float>? {
        guard worldProvider.state == .running,
              let device = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }
        let m = device.originFromAnchorTransform
        return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Head position plus the direction it faces, for content that has to sit in front
    /// of the viewer rather than beside a hand. Forward is -Z of the device anchor,
    /// flattened to the horizontal plane: a banner placed along a downward-tilted gaze
    /// would end up at the user's feet.
    var headWorldPose: (position: SIMD3<Float>, forward: SIMD3<Float>)? {
        guard worldProvider.state == .running,
              let device = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }
        let m = device.originFromAnchorTransform
        let position = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var forward = SIMD3<Float>(-m.columns.2.x, 0, -m.columns.2.z)
        let length = simd_length(forward)
        // Looking straight up or down leaves no horizontal component to normalise.
        guard length > 1e-4 else { return nil }
        forward /= length
        return (position, forward)
    }

    /// How squarely a palm faces the viewer — the wrist HUD's summon gesture.
    ///
    /// A plain dot product, deliberately, rather than the pitch-invariant variant
    /// used elsewhere. Stripping the finger-axis component suits a use case
    /// that wants a forgiving trigger, but here it widens the engaging cone until the
    /// panel shows up on almost any orientation with a sideways component. "Turn your
    /// palm toward your face" should mean exactly that.
    func palmFacing(_ hand: BridgeHand) -> Float? {
        guard let head = headWorldPosition else { return nil }
        return gestureEngine.palmFacing(hand, towards: head)
    }

    func palmPose(_ hand: BridgeHand) -> RAVEPalmPose? {
        gestureEngine.palmPose(hand)
    }

    func thumbTipWorld(_ hand: BridgeHand) -> SIMD3<Float>? {
        gestureEngine.thumbTipWorld(hand)
    }

    /// Stop a hand's pinches reaching the game while it is holding the HUD.
    func setGestureSuppressed(_ suppressed: Bool, for hand: BridgeHand) {
        if suppressed { gestureEngine.suppressedHands.insert(hand) }
        else { gestureEngine.suppressedHands.remove(hand) }
    }

    private func headBasis() -> (forward: SIMD3<Float>, right: SIMD3<Float>) {
        var forward = SIMD3<Float>(0, 0, -1)
        var right = SIMD3<Float>(1, 0, 0)
        if worldProvider.state == .running,
           let device = worldProvider.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) {
            let m = device.originFromAnchorTransform
            let f = SIMD3<Float>(-m.columns.2.x, 0, -m.columns.2.z)
            let r = SIMD3<Float>(m.columns.0.x, 0, m.columns.0.z)
            if simd_length(f) > 1e-4 { forward = simd_normalize(f) }
            if simd_length(r) > 1e-4 { right = simd_normalize(r) }
        }
        return (forward, right)
    }

    /// Swap in a new gesture→input map (e.g. from the settings UI). Takes effect next frame.
    func updateGestureMapping(_ mapping: GestureControllerMapping) {
        gestureMapping = mapping
    }

    /// UDP whenever we lawfully can (an endpoint plus either session keys or the dev
    /// plaintext opt-in — the datagram channel enforces that); the message channel
    /// only until then.
    ///
    /// The order is deliberate and load-bearing. The channel dies on its own after
    /// about twelve seconds on the CloudXR host — it is the bootstrap, never the
    /// transport — and sealing is not optional: a packet that cannot be sealed is
    /// dropped rather than downgraded (see BridgeDatagramChannel).
    private func send(_ data: Data) {
        if datagram.isReady {
            datagram.send(data)
            return
        }
        // No usable direct link yet — before the rendezvous lands, or a host that
        // cannot open sealed input. The channel is CloudXR-encrypted, so input on it
        // is safe; it just does not last, which is why this is only the bootstrap.
        if let channel = messageChannel, channel.channelStatus == .ready {
            do { try channel.sendMessage(data) } catch {
                lastSendError = error.localizedDescription
            }
        }
    }
}
#endif
