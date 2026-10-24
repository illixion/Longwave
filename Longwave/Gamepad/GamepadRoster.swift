import DebugTrace
import Foundation
import GameController
import RAVEInput

/// Every extended gamepad the app reads, claimed in one place and shared by every reader.
///
/// Moonlight and the PCVR controller bridge each used to find, claim and read pads
/// themselves, and the two fought over the parts of GameController that hold only one
/// owner. `valueChangedHandler` is a single slot: a second Moonlight session replaced
/// the first one's handler, and when that session ended the first was left with a dead
/// one and no input. `preferredSystemGestureState` was switched back on by whichever
/// reader stopped first. And the bridge claimed nothing at all (no player index, no
/// handler), which is the visionOS trap `RAVEGamepadSource` documents: a pad nobody
/// consumes stays the system's, and polled sticks freeze once released.
///
/// So the roster is the only thing that touches those properties. While anyone is
/// subscribed it holds every extended gamepad in a slot (0–3, which is also its player
/// index and Moonlight's controller number), installs one change handler per pad and
/// fans it out, keeps the system's gestures off the pad's buttons, and powers a pad's
/// motion sensors while some subscriber asks for them. Readers then map
/// `RAVEGamepadSnapshot`s into their own wire format.
///
/// The other half of the claim lives in the views: `.handlesGameControllerEvents(matching:
/// .gamepad)` on whatever is hosting the content.
///
/// Main actor: GameController delivers its notifications and handlers on the main queue
/// (nothing here changes `GCController.handlerQueue`), and the PCVR bridge polls from
/// the main actor too.
final class GamepadRoster {

    static let shared = GamepadRoster()

    /// Moonlight addresses at most four pads, and the player-index LEDs stop at four.
    static let slotCount = 4

    /// A subscriber's handle. Keep it to unsubscribe and to ask for motion.
    final class Subscription {
        fileprivate let connected: (Int, GCController) -> Void
        fileprivate let disconnected: (Int, GCController) -> Void
        fileprivate let changed: ((Int, RAVEGamepadSnapshot) -> Void)?

        fileprivate init(connected: @escaping (Int, GCController) -> Void,
                         disconnected: @escaping (Int, GCController) -> Void,
                         changed: ((Int, RAVEGamepadSnapshot) -> Void)?) {
            self.connected = connected
            self.disconnected = disconnected
            self.changed = changed
        }
    }

    /// Slot → pad. Empty while nobody is subscribed.
    private(set) var controllers: [Int: GCController] = [:]

    /// One bit per occupied slot: Moonlight's active gamepad mask.
    var activeMask: UInt16 {
        controllers.keys.reduce(0) { $0 | UInt16(1 << $1) }
    }

    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    /// Which subscribers want each slot's motion sensors on.
    private var motionDemand: [Int: Set<ObjectIdentifier>] = [:]
    private var observers: [NSObjectProtocol] = []
    private let log = DebugLogger(subsystem: "pro.longwave", category: "GamepadRoster")

    private init() {}

    // MARK: Subscribing

    /// Start receiving pads. `connected` is called at once for every pad already held,
    /// in slot order, then for each new arrival; `disconnected` after a pad has left its
    /// slot. `changed`, when given, gets a snapshot (without motion) on every input
    /// change — for readers that send on change rather than polling.
    func subscribe(connected: @escaping (_ slot: Int, GCController) -> Void,
                   disconnected: @escaping (_ slot: Int, GCController) -> Void,
                   changed: ((_ slot: Int, RAVEGamepadSnapshot) -> Void)? = nil) -> Subscription {
        let subscription = Subscription(connected: connected, disconnected: disconnected,
                                        changed: changed)
        let wasIdle = subscriptions.isEmpty
        subscriptions[ObjectIdentifier(subscription)] = subscription
        if wasIdle {
            startWatching()
        } else {
            for slot in controllers.keys.sorted() {
                if let controller = controllers[slot] { connected(slot, controller) }
            }
        }
        return subscription
    }

    /// Stop receiving pads and drop the subscriber's motion requests. The last one out
    /// releases every pad back to the system.
    func unsubscribe(_ subscription: Subscription) {
        let id = ObjectIdentifier(subscription)
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        for slot in Array(motionDemand.keys) { setMotion(false, slot: slot, for: id) }
        if subscriptions.isEmpty { stopWatching() }
    }

    // MARK: Reading

    func slot(of controller: GCController) -> Int? {
        controllers.first(where: { $0.value === controller })?.key
    }

    /// The pad in `slot` read now, motion included where its sensors are on.
    func snapshot(slot: Int) -> RAVEGamepadSnapshot? {
        guard let controller = controllers[slot], let pad = controller.extendedGamepad else { return nil }
        var snapshot = RAVEGamepadSnapshot(pad, motion: controller.motion)
        #if DEBUG
        if let virtual = virtualPads[ObjectIdentifier(controller)] {
            snapshot.rotationRate = virtual.gyro ? virtual.rotationRate : nil
            snapshot.acceleration = virtual.accelerometer ? virtual.acceleration : nil
        }
        #endif
        return snapshot
    }

    /// Which motion sensors the pad in `slot` has. Readers ask here rather than reading
    /// `GCMotion` themselves, so a debug virtual pad can declare sensors it has no
    /// `GCMotion` for.
    func motionSensors(slot: Int) -> (gyro: Bool, accelerometer: Bool) {
        guard let controller = controllers[slot] else { return (false, false) }
        #if DEBUG
        if let virtual = virtualPads[ObjectIdentifier(controller)] {
            return (virtual.gyro, virtual.accelerometer)
        }
        #endif
        guard let motion = controller.motion else { return (false, false) }
        return (motion.hasRotationRate, motion.hasGravityAndUserAcceleration)
    }

    /// How many subscribers want `slot`'s motion sensors on (for the debug status).
    func motionRequests(slot: Int) -> Int { motionDemand[slot]?.count ?? 0 }

    var subscriberCount: Int { subscriptions.count }

    /// Ask for (or stop asking for) the motion sensors of the pad in `slot`. They run
    /// while at least one subscriber wants them: powering a pad's IMU costs its battery,
    /// so nobody gets it by default.
    func setMotionWanted(_ wanted: Bool, slot: Int, by subscription: Subscription) {
        setMotion(wanted, slot: slot, for: ObjectIdentifier(subscription))
    }

    private func setMotion(_ wanted: Bool, slot: Int, for id: ObjectIdentifier) {
        var demand = motionDemand[slot] ?? []
        let wasOn = !demand.isEmpty
        if wanted { demand.insert(id) } else { demand.remove(id) }
        motionDemand[slot] = demand.isEmpty ? nil : demand
        guard wasOn != !demand.isEmpty, let motion = controllers[slot]?.motion else { return }
        motion.sensorsActive = !demand.isEmpty
    }

    // MARK: Claiming

    private func startWatching() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                MainActor.assumeIsolated { self?.claim(controller) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) {
                [weak self] note in
                guard let controller = note.object as? GCController else { return }
                MainActor.assumeIsolated { self?.release(controller, departing: true) }
            },
        ]
        for controller in GCController.controllers() { claim(controller) }
    }

    private func stopWatching() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        for controller in controllers.values { release(controller, departing: false) }
    }

    private func claim(_ controller: GCController) {
        // Spatial controllers (PSVR2 Sense) are per-hand devices with their own source in
        // RAVEInput, and carry no extended profile anyway.
        // (The constant is macOS 26+; the Mac client runs on 14, where they don't exist.)
        if #available(macOS 26, *), controller.productCategory == GCProductCategorySpatialController { return }
        guard let pad = controller.extendedGamepad else { return }
        guard slot(of: controller) == nil else { return }
        guard let slot = (0..<Self.slotCount).first(where: { controllers[$0] == nil }) else {
            log.notice("Every gamepad slot is taken; ignoring another pad.")
            return
        }
        controllers[slot] = controller
        controller.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset
        // Registering a handler is what makes the app a persistent consumer of the pad;
        // without it polled values freeze. It also serves the readers that send on change.
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            MainActor.assumeIsolated { self?.changed(gamepad, slot: slot) }
        }
        // Keep visionOS from turning buttons into system actions (a shoulder press
        // becoming a look-and-pinch) while a stream has the pad.
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        log.notice("""
            Pad \(slot, privacy: .public) claimed: \(controller.vendorName ?? "unknown") \
            (motion: \(controller.motion?.hasRotationRate == true ? "gyro" : "none", privacy: .public)).
            """)
        for subscription in Array(subscriptions.values) { subscription.connected(slot, controller) }
    }

    /// `departing`: the pad disconnected. Otherwise the last subscriber left and the pad
    /// goes back to the system, so subscribers (there are none) are not told.
    private func release(_ controller: GCController, departing: Bool) {
        guard let slot = slot(of: controller) else { return }
        controllers.removeValue(forKey: slot)
        #if DEBUG
        virtualPads.removeValue(forKey: ObjectIdentifier(controller))
        #endif
        if motionDemand.removeValue(forKey: slot) != nil { controller.motion?.sensorsActive = false }
        controller.extendedGamepad?.valueChangedHandler = nil
        controller.playerIndex = .indexUnset
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .enabled
        }
        log.notice("Pad \(slot, privacy: .public) released.")
        guard departing else { return }
        for subscription in Array(subscriptions.values) { subscription.disconnected(slot, controller) }
    }

    private func changed(_ pad: GCExtendedGamepad, slot: Int) {
        // Built only when someone listens for changes; the bridge polls instead.
        var snapshot: RAVEGamepadSnapshot?
        for subscription in subscriptions.values {
            guard let changed = subscription.changed else { continue }
            if snapshot == nil { snapshot = RAVEGamepadSnapshot(pad) }
            changed(slot, snapshot!)
        }
    }

    // MARK: Virtual pads (debug)
    //
    // A pad an agent drives through the debug server, so a stream can be tested end to
    // end without anyone holding a controller: `GCController.withExtendedGamepad()` is a
    // real controller object whose elements take values from code. It is claimed and
    // fanned out like a physical pad, and reports as GameController's generic extended
    // gamepad — which Moonlight announces as a Nintendo pad, the same as a Switch Pro.
    // It has no `GCMotion`, so its sensors are declared here and their readings set
    // directly. See `GamepadDebugEndpoints`.

    #if DEBUG
    struct VirtualPad {
        var gyro: Bool
        var accelerometer: Bool
        var rotationRate: SIMD3<Float> = .zero
        /// At rest, flat: gravity straight down in GameController's axes.
        var acceleration: SIMD3<Float> = SIMD3(0, 0, -1)
    }

    private var virtualPads: [ObjectIdentifier: VirtualPad] = [:]

    func isVirtual(slot: Int) -> Bool {
        controllers[slot].map { virtualPads[ObjectIdentifier($0)] != nil } ?? false
    }

    /// Adds a virtual pad and returns its slot: nil while nobody is subscribed (there is
    /// no stream to drive) or every slot is taken.
    func addVirtualPad(gyro: Bool, accelerometer: Bool) -> Int? {
        guard !subscriptions.isEmpty else { return nil }
        let controller = GCController.withExtendedGamepad()
        virtualPads[ObjectIdentifier(controller)] = VirtualPad(gyro: gyro, accelerometer: accelerometer)
        claim(controller)
        guard let slot = slot(of: controller) else {
            virtualPads.removeValue(forKey: ObjectIdentifier(controller))
            return nil
        }
        return slot
    }

    /// Sets the whole state of the virtual pad in `slot` and delivers it as one change.
    /// Returns false when `slot` holds no virtual pad.
    func setVirtualPad(slot: Int, to state: RAVEGamepadSnapshot) -> Bool {
        guard let controller = controllers[slot], let pad = controller.extendedGamepad,
              var virtual = virtualPads[ObjectIdentifier(controller)] else { return false }
        func set(_ element: GCControllerButtonInput?, _ button: RAVEGamepadSnapshot.Buttons) {
            element?.setValue(state.buttons.contains(button) ? 1 : 0)
        }
        set(pad.buttonA, .a)
        set(pad.buttonB, .b)
        set(pad.buttonX, .x)
        set(pad.buttonY, .y)
        set(pad.leftShoulder, .leftShoulder)
        set(pad.rightShoulder, .rightShoulder)
        set(pad.leftThumbstickButton, .leftStick)
        set(pad.rightThumbstickButton, .rightStick)
        set(pad.buttonMenu, .menu)
        set(pad.buttonOptions, .options)
        set(pad.buttonHome, .home)
        func axis(_ positive: RAVEGamepadSnapshot.Buttons, _ negative: RAVEGamepadSnapshot.Buttons) -> Float {
            (state.buttons.contains(positive) ? 1 : 0) - (state.buttons.contains(negative) ? 1 : 0)
        }
        pad.dpad.setValueForXAxis(axis(.dpadRight, .dpadLeft), yAxis: axis(.dpadUp, .dpadDown))
        pad.leftThumbstick.setValueForXAxis(state.leftStick.x, yAxis: state.leftStick.y)
        pad.rightThumbstick.setValueForXAxis(state.rightStick.x, yAxis: state.rightStick.y)
        // A trigger's press follows its value, at GameController's own threshold, as on
        // a real pad; the snapshot's trigger bits are not set separately.
        pad.leftTrigger.setValue(state.leftTrigger)
        pad.rightTrigger.setValue(state.rightTrigger)
        virtual.rotationRate = state.rotationRate ?? .zero
        virtual.acceleration = state.acceleration ?? SIMD3(0, 0, -1)
        virtualPads[ObjectIdentifier(controller)] = virtual
        // Setting values may or may not fire the change handler for a controller nobody
        // physically holds; deliver the finished state once either way.
        changed(pad, slot: slot)
        return true
    }

    /// Disconnects the virtual pad in `slot`, as if it were unplugged. Returns false when
    /// `slot` holds no virtual pad.
    func removeVirtualPad(slot: Int) -> Bool {
        guard isVirtual(slot: slot), let controller = controllers[slot] else { return false }
        release(controller, departing: true)
        return true
    }
    #endif
}
