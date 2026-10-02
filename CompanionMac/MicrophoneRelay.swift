import AVFoundation
import CoreAudio
import DebugTrace
import Foundation
import os

/// Plays the headset's microphone into a virtual audio device, so any app on
/// this Mac can pick it as a microphone — ChatGPT's voice mode, a Meet call.
///
/// macOS offers no way for an app to publish an input device of its own short
/// of an audio driver, so this leans on one the user installs: BlackHole
/// (`brew install blackhole-2ch`) is a loopback, so what plays into its output
/// comes straight back out of its input. The relay finds it by name and never
/// links or bundles it.
///
/// Packets arrive on the stream server's queue; Core Audio pulls samples on
/// its render thread. Between the two sits a small jitter cushion that starts
/// at 40 ms, grows when the link stalls, and is trimmed whenever it holds more
/// than it needs — every sample queued here is latency in someone's call.
nonisolated final class MicrophoneRelay: @unchecked Sendable {

    enum Status: Equatable, Sendable {
        /// No BlackHole (or other loopback) device is installed.
        case noDevice
        /// The device is there; nothing is arriving from the headset.
        case ready(deviceName: String)
        /// Headset audio is playing into the device.
        case live(deviceName: String)
        case failed(String)
    }

    /// Main actor; fired whenever `Status` changes.
    var onStatusChange: (@MainActor @Sendable (Status) -> Void)?

    private let log = DebugLogger(subsystem: "pro.longwave.companion", category: "MicrophoneRelay")
    private let queue = DispatchQueue(label: "pro.longwave.companion.microphone", qos: .userInteractive)

    // All on `queue`.
    private var engine: AVAudioEngine?
    private var engineRate: Double = 0
    private var engineChannels = 0
    private var deviceName: String?
    private var expectedIndex: UInt64?
    private var lastPacketNanos: UInt64 = 0
    private var idleTimer: DispatchSourceTimer?
    private var status: Status = .noDevice
    private var lastHealthLogNanos: UInt64 = 0

    private let jitter = JitterBuffer()

    init() {}

    /// The loopback device the relay plays into, if one is installed.
    static func findLoopbackDevice() -> (id: AudioDeviceID, name: String)? {
        AudioDevices.outputDevices().first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    /// Whether a headset can be offered the microphone at all.
    var isAvailable: Bool { Self.findLoopbackDevice() != nil }

    func refreshStatus() {
        queue.async { [self] in
            if engine == nil { publishIdleStatus() }
        }
    }

    /// One packet from the headset. Called on the stream server's queue.
    func receive(_ packet: MicrophonePacket) {
        queue.async { [self] in
            handle(packet)
        }
    }

    /// The headset said it stopped; release the device now.
    func headsetStopped() {
        queue.async { [self] in
            log.info("Headset microphone stopped")
            stopEngine()
        }
    }

    func stop() {
        queue.sync { stopEngine() }
    }

    // MARK: - Packets (on `queue`)

    private func handle(_ packet: MicrophonePacket) {
        lastPacketNanos = DispatchTime.now().uptimeNanoseconds
        if engine == nil || engineRate != packet.sampleRate || engineChannels != packet.channelCount {
            stopEngine()
            guard startEngine(sampleRate: packet.sampleRate, channels: packet.channelCount) else { return }
            expectedIndex = nil
        }

        let frames = packet.frameCount
        guard frames > 0 else { return }
        let resumed = packet.stamp.flags.contains(.resumed)
        if let expected = expectedIndex, !resumed {
            if packet.stamp.sampleIndex < expected {
                // Late or duplicated: what it would fill has already played.
                return
            }
            let gap = packet.stamp.sampleIndex - expected
            if gap > 0 {
                // Lost on the way. Fill a short hole with silence so what
                // follows keeps its timing; a long one is a stall, and the
                // cushion re-primes instead.
                let maxFill = UInt64(packet.sampleRate * 0.1)
                if gap <= maxFill {
                    jitter.appendSilence(frames: Int(gap) * packet.channelCount)
                }
            }
        }
        expectedIndex = packet.stamp.sampleIndex + UInt64(frames)
        packet.samples.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            jitter.append(int24: bytes, sampleCount: frames * packet.channelCount)
        }
        if case .live = status {} else if let deviceName {
            publish(.live(deviceName: deviceName))
        }
        logHealthIfNeeded()
    }

    private func logHealthIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastHealthLogNanos > 10_000_000_000 else { return }
        lastHealthLogNanos = now
        let health = jitter.takeHealth()
        log.info("Headset microphone: cushion \(Int(health.targetSeconds * 1000)) ms, \(health.underruns) underruns, \(health.trimmedFrames) frames trimmed")
    }

    // MARK: - Engine (on `queue`)

    private func startEngine(sampleRate: Double, channels: Int) -> Bool {
        guard let device = Self.findLoopbackDevice() else {
            publish(.noDevice)
            return false
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: true
        ) else { return false }

        let engine = AVAudioEngine()
        // Point the output at the loopback before anything else touches the
        // engine's output node, so its format is the device's.
        guard let outputUnit = engine.outputNode.audioUnit else { return false }
        var deviceID = device.id
        let setStatus = AudioUnitSetProperty(
            outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else {
            log.error("Could not route to the loopback device (\(setStatus))")
            publish(.failed("Could not open \(device.name) (\(setStatus))."))
            return false
        }

        jitter.reset(sampleRate: sampleRate, channels: channels)
        let jitter = self.jitter
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = buffers.first, let data = first.mData else { return noErr }
            let samples = Int(frameCount) * channels
            jitter.render(into: data.assumingMemoryBound(to: Float.self), sampleCount: samples)
            return noErr
        }
        engine.attach(source)
        // Mono reaches both of BlackHole's channels through the mixer, so an
        // app reading either one hears the voice.
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            log.error("Could not start microphone output: \(error.localizedDescription)")
            publish(.failed("Could not start \(device.name): \(error.localizedDescription)"))
            return false
        }
        self.engine = engine
        engineRate = sampleRate
        engineChannels = channels
        deviceName = device.name
        log.info("Headset microphone → \(device.name, privacy: .public) at \(Int(sampleRate)) Hz, \(channels) ch")
        publish(.live(deviceName: device.name))
        startIdleTimer()
        return true
    }

    private func stopEngine() {
        idleTimer?.cancel()
        idleTimer = nil
        engine?.stop()
        engine = nil
        engineRate = 0
        engineChannels = 0
        expectedIndex = nil
        publishIdleStatus()
    }

    /// Lets go of the device once the headset has gone quiet without saying
    /// so — it dropped off the network, or its app was suspended.
    private func startIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.engine != nil else { return }
            if DispatchTime.now().uptimeNanoseconds &- self.lastPacketNanos > 3_000_000_000 {
                self.log.info("Headset microphone went quiet; releasing the device")
                self.stopEngine()
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func publishIdleStatus() {
        if let device = Self.findLoopbackDevice() {
            publish(.ready(deviceName: device.name))
        } else {
            publish(.noDevice)
        }
    }

    private func publish(_ new: Status) {
        guard new != status else { return }
        status = new
        guard let onStatusChange else { return }
        Task { @MainActor in onStatusChange(new) }
    }
}

// MARK: - Jitter buffer

/// Interleaved Float32 FIFO between the network and the render thread.
///
/// The render side takes the lock only for a copy, never allocates, and plays
/// silence while it waits for the cushion to fill — after start, and again
/// after an underrun, which also grows the cushion so the same stall doesn't
/// starve it twice.
nonisolated final class JitterBuffer: @unchecked Sendable {
    struct Health {
        var targetSeconds: Double
        var underruns: Int
        var trimmedFrames: Int
    }

    private static let baseTarget = 0.04
    private static let maxTarget = 0.16
    /// Held beyond the target before the oldest audio is dropped.
    private static let trimSlack = 0.06

    private var lock = os_unfair_lock()
    private var storage: UnsafeMutablePointer<Float>
    private var capacity: Int
    private var readIndex = 0
    private var count = 0
    private var channels = 1
    private var sampleRate: Double = 48_000
    private var targetSeconds = JitterBuffer.baseTarget
    private var priming = true
    private var underruns = 0
    private var trimmedFrames = 0

    init() {
        capacity = 48_000 * 2
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Network side: reshapes the buffer for a new format. Never called while
    /// a render is running (the engine is stopped first).
    func reset(sampleRate: Double, channels: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let needed = Int(sampleRate) * channels   // one second
        if needed > capacity {
            storage.deallocate()
            capacity = needed
            storage = .allocate(capacity: capacity)
            storage.initialize(repeating: 0, count: capacity)
        }
        self.sampleRate = sampleRate
        self.channels = channels
        readIndex = 0
        count = 0
        targetSeconds = Self.baseTarget
        priming = true
    }

    func append(int24 bytes: UnsafeBufferPointer<UInt8>, sampleCount: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let samples = min(sampleCount, bytes.count / AudioStreamProtocol.bytesPerSample)
        for i in 0..<samples {
            push(PCM24.sample(bytes, at: i * AudioStreamProtocol.bytesPerSample))
        }
        trimIfNeeded()
    }

    func appendSilence(frames samples: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for _ in 0..<samples { push(0) }
    }

    /// Render side — the Core Audio thread.
    func render(into destination: UnsafeMutablePointer<Float>, sampleCount: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let target = Int(targetSeconds * sampleRate) * channels
        if priming {
            guard count >= target else {
                destination.update(repeating: 0, count: sampleCount)
                return
            }
            priming = false
        }
        let available = min(count, sampleCount)
        for i in 0..<available {
            destination[i] = storage[(readIndex + i) % capacity]
        }
        readIndex = (readIndex + available) % capacity
        count -= available
        if available < sampleCount {
            (destination + available).update(repeating: 0, count: sampleCount - available)
            underruns += 1
            priming = true
            targetSeconds = min(Self.maxTarget, targetSeconds + 0.02)
        }
    }

    func takeHealth() -> Health {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let health = Health(targetSeconds: targetSeconds, underruns: underruns, trimmedFrames: trimmedFrames)
        underruns = 0
        trimmedFrames = 0
        return health
    }

    // Under the lock.
    private func push(_ sample: Float) {
        if count == capacity {
            readIndex = (readIndex + 1) % capacity
            count -= 1
        }
        storage[(readIndex + count) % capacity] = sample
        count += 1
    }

    // Under the lock.
    private func trimIfNeeded() {
        let limit = Int((targetSeconds + Self.trimSlack) * sampleRate) * channels
        guard !priming, count > limit else { return }
        let keep = Int(targetSeconds * sampleRate) * channels
        let drop = (count - keep) / channels * channels
        readIndex = (readIndex + drop) % capacity
        count -= drop
        trimmedFrames += drop / channels
    }
}

// MARK: - Device lookup

nonisolated enum AudioDevices {
    /// Every device with at least one output stream, by Core Audio id and name.
    static func outputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return (id, name)
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}
