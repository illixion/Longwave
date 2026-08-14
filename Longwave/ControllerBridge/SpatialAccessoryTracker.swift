//  SpatialAccessoryTracker.swift
//
//  Best-effort 6DoF tracking for spatial game controllers (PSVR2 Sense, and
//  whatever else reports GCProductCategorySpatialController) feeding the
//  controller bridge. Each tracked controller supplies the pose, angular
//  velocity, and buttons for ITS hand — replacing the hand-tracking wrist pose
//  and the single-gamepad IMU-attribution dance for that side, since a spatial
//  controller knows which hand it is and where it is.
//
//  "Best-effort" is structural: `AccessoryTrackingProvider.isSupported` is
//  false in the simulator and on anything without the tracking stack, and no
//  spatial accessory can connect there anyway, so everything here sits dormant
//  until a real controller arrives on a real device. Nothing else in the
//  bridge changes behavior when this class has nothing to say — the wrist
//  poses and Switch Pro path carry on exactly as before. This has NOT yet run
//  against real hardware (no Sense controllers on hand); the API surface is
//  compiled against the 26.5 SDK and the integration is designed to fail
//  toward the existing paths.
//
//  Coordinate space: AccessoryAnchor.originFromAnchorTransform is in the same
//  ARKit world origin the HandTrackingProvider anchors use, which is exactly
//  what the host's alignment expects — no new calibration is introduced. The
//  anchor origin is the accessory's own; games mount things on the OpenXR grip
//  pose, and the host already carries grip-offset tuning, so v1 ships the
//  anchor pose as-is rather than resolving `coordinateSpace(for: .grip)`
//  (worth revisiting once real hardware shows the residual).

#if FOVEATED_ENABLED
import Foundation
import ARKit
import GameController
import RAVEInput
import simd
import QuartzCore
import os

@MainActor
@Observable
final class SpatialAccessoryTracker {

    /// The latest word on one hand's controller: where it is, how it turns,
    /// and whether ARKit currently trusts the pose.
    struct Snapshot {
        var pose = ControllerBridgeHandPose()
        var isTracked = false
        var updatedAt: TimeInterval = 0
    }

    /// Per-hand pose snapshots, written by the anchor loop. `nil` until a
    /// controller of that chirality has produced an anchor.
    private(set) var left: Snapshot?
    private(set) var right: Snapshot?

    /// The spatial controllers by chirality, for button reads and haptics.
    /// Chirality comes from the ARKit `Accessory` (`inherentChirality`,
    /// refined by `heldChirality` on anchors) — GameController alone does not
    /// say which hand a Sense controller is.
    private(set) var controllers: [BridgeHand: GCController] = [:]

    /// True while at least one spatial controller is connected and the
    /// provider is running — the HUD's "why is my hand pose different" answer.
    var isActive: Bool { !controllers.isEmpty && providerTask != nil }

    private let log = Logger(subsystem: "pro.longwave", category: "SpatialAccessory")
    private var observers: [NSObjectProtocol] = []
    /// Accessories by the controller they wrap, so a disconnect can drop the
    /// right one. Keyed by ObjectIdentifier — GCController is not Hashable.
    private var accessories: [ObjectIdentifier: (controller: GCController, accessory: Accessory)] = [:]
    private var session: ARKitSession?
    private var provider: AccessoryTrackingProvider?
    private var providerTask: Task<Void, Never>?
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        guard AccessoryTrackingProvider.isSupported else {
            log.notice("Accessory tracking unsupported here; spatial controllers inactive.")
            return
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in self?.adoptIfSpatial(controller) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor in self?.forget(controller) }
            },
        ]
        for existing in GCController.controllers() { adoptIfSpatial(existing) }
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver(_:))
        observers = []
        stopProvider()
        session?.stop()
        session = nil
        accessories.removeAll()
        controllers.removeAll()
        left = nil
        right = nil
    }

    /// The freshest tracked pose for a hand, or nil when the controller is
    /// absent, untracked, or stale (dropout ages out in a quarter second so a
    /// parked controller hands the pose back to the wrist).
    func trackedPose(for hand: BridgeHand, now: TimeInterval) -> ControllerBridgeHandPose? {
        guard let snap = hand == .left ? left : right else { return nil }
        guard snap.isTracked, now - snap.updatedAt < 0.25 else { return nil }
        return snap.pose
    }

    // MARK: Discovery

    private func adoptIfSpatial(_ controller: GCController) {
        guard controller.productCategory == GCProductCategorySpatialController else { return }
        let id = ObjectIdentifier(controller)
        guard accessories[id] == nil else { return }
        log.notice("""
            Spatial controller connected: \
            \(controller.vendorName ?? "unknown", privacy: .public)
            """)
        Task { @MainActor [weak self] in
            do {
                let accessory = try await Accessory(device: controller)
                guard let self, self.running else { return }
                self.accessories[id] = (controller, accessory)
                switch accessory.inherentChirality {
                case .left: self.controllers[.left] = controller
                case .right: self.controllers[.right] = controller
                case .unspecified:
                    // A one-handed accessory with no fixed side (a stylus-like
                    // device); heldChirality on its anchors will place it.
                    break
                @unknown default:
                    break
                }
                await self.restartProvider()
            } catch {
                self?.log.error("""
                    Accessory creation failed for \
                    \(controller.vendorName ?? "unknown", privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    private func forget(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard accessories.removeValue(forKey: id) != nil else { return }
        for (hand, held) in controllers where held === controller {
            controllers[hand] = nil
            if hand == .left { left = nil } else { right = nil }
        }
        log.notice("Spatial controller disconnected.")
        Task { @MainActor [weak self] in await self?.restartProvider() }
    }

    // MARK: Provider lifecycle

    /// (Re)run tracking over the current accessory set. The provider's set is
    /// fixed at init, so any membership change means a fresh provider — and a
    /// data provider instance cannot be re-run, so a fresh session too.
    private func restartProvider() async {
        stopProvider()
        session?.stop()
        session = nil
        guard running, !accessories.isEmpty else { return }

        let session = ARKitSession()
        self.session = session
        let auth = await session.requestAuthorization(for: [.accessoryTracking])
        guard auth[.accessoryTracking] == .allowed else {
            log.notice("Accessory-tracking authorization denied; spatial poses unavailable.")
            return
        }
        let provider = AccessoryTrackingProvider(
            accessories: accessories.values.map(\.accessory))
        self.provider = provider
        do {
            try await session.run([provider])
        } catch {
            log.error("Accessory tracking run failed: \(error.localizedDescription, privacy: .public)")
            self.provider = nil
            return
        }
        providerTask = Task { @MainActor [weak self] in
            for await update in provider.anchorUpdates {
                if Task.isCancelled { break }
                self?.ingest(update.anchor)
            }
        }
        log.notice("Accessory tracking running over \(self.accessories.count) accessorie(s).")
    }

    private func stopProvider() {
        providerTask?.cancel()
        providerTask = nil
        provider = nil
    }

    // MARK: Anchors

    private func ingest(_ anchor: AccessoryAnchor) {
        // A held side beats the built-in one: `heldChirality` is ARKit's live
        // judgement, `inherentChirality` the device's nature. For a Sense pair
        // they agree; for an unspecified-chirality accessory only the former
        // ever places it.
        let chirality = anchor.heldChirality ?? anchor.accessory.inherentChirality
        let hand: BridgeHand
        switch chirality {
        case .left: hand = .left
        case .right: hand = .right
        default: return
        }

        let m = anchor.originFromAnchorTransform
        var snap = Snapshot()
        snap.pose.position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        snap.pose.orientation = simd_quatf(simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        // A real per-device gyro — the whole IMU-attribution problem the
        // Switch Pro path solves does not exist here.
        snap.pose.gyro = anchor.angularVelocity
        // Orientation-only tracking still yields a usable rotation, but the
        // position would be stale; treat only full 6DoF states as tracked and
        // let the wrist pose carry the hand through occlusion.
        switch anchor.trackingState {
        case .positionOrientationTracked, .positionOrientationTrackedLowAccuracy:
            snap.isTracked = true
        default:
            snap.isTracked = false
        }
        snap.updatedAt = CACurrentMediaTime()
        if hand == .left { left = snap } else { right = snap }
    }
}
#endif
