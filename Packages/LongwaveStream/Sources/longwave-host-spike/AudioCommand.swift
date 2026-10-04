// SPIKE ONLY: WASAPI loopback of a render endpoint into a WAV file, keeping
// every channel, then a per-channel check of what was captured.
//
// With --tones the spike also plays a distinct sine on each channel of the same
// endpoint (channel n at 250 * (n + 1) Hz), so the check can confirm that each
// channel arrived on the right index, not just that the file has N channels.
import Dispatch
import StreamHostWindows
import Synchronization
import WinSDK
import ucrt

final class AudioCollector: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private(set) var bytes: [UInt8] = []
    private(set) var buffers = 0
    private(set) var silentBuffers = 0
    private(set) var discontinuities = 0
    private(set) var gapFrames = 0
    private var expectedNextTicks: Int64 = 0
    private let bytesPerFrame: Int
    private let sampleRate: Int

    init(bytesPerFrame: Int, sampleRate: Int) {
        self.bytesPerFrame = bytesPerFrame
        self.sampleRate = sampleRate
    }

    func append(_ buffer: AudioLoopback.Buffer) {
        lock.withLock { _ in
            buffers += 1
            if buffer.isSilent { silentBuffers += 1 }
            if buffer.followsDiscontinuity { discontinuities += 1 }
            // Loopback sends nothing while the endpoint is idle. Fill such gaps
            // with silence so the file keeps real time.
            if expectedNextTicks != 0 {
                let gap = buffer.captureTicks - expectedNextTicks
                let gapFrames = Int(gap * Int64(sampleRate) / HostClock.ticksPerSecond)
                if gapFrames > sampleRate / 100 { // > 10 ms
                    self.gapFrames += gapFrames
                    bytes.append(contentsOf: repeatElement(0, count: gapFrames * bytesPerFrame))
                }
            }
            if let samples = buffer.samples {
                bytes.append(contentsOf: samples)
            } else {
                bytes.append(contentsOf: repeatElement(0, count: buffer.frames * bytesPerFrame))
            }
            expectedNextTicks = buffer.captureTicks + Int64(buffer.frames) * HostClock.ticksPerSecond / Int64(sampleRate)
        }
    }

    func snapshot() -> [UInt8] { lock.withLock { _ in bytes } }
}

func runAudio(options: Options) {
    let endpoints = AudioLoopback.endpoints()
    for (index, endpoint) in endpoints.enumerated() { print("[\(index)] \(endpoint)") }
    let choice = options.string("endpoint", "default")
    let endpoint: AudioLoopback.Endpoint?
    if choice == "default" {
        endpoint = endpoints.first(where: \.isDefault)
    } else if let match = endpoints.first(where: { $0.name.contains(choice) }) {
        // By name: indices shift when devices come and go (a monitor waking
        // adds its HDMI/DP audio endpoint), so never select by index.
        endpoint = match
    } else {
        fail("no endpoint \(choice)")
    }
    let seconds = options.double("seconds", 4)
    let path = options.string("out", "loopback.wav")
    print("capturing \(endpoint?.name ?? "default endpoint") for \(seconds) s")

    var collector: AudioCollector?
    let loopback: AudioLoopback
    do {
        let holder = Mutex<AudioCollector?>(nil)
        loopback = try AudioLoopback(endpointID: endpoint?.id) { buffer in
            holder.withLock { $0 }?.append(buffer)
        }
        let format = loopback.format
        collector = AudioCollector(bytesPerFrame: format.bytesPerFrame, sampleRate: format.sampleRate)
        holder.withLock { $0 = collector }
        print("format: \(format.channels) ch, \(format.sampleRate) Hz, \(format.bitsPerSample)-bit \(format.isFloat ? "float" : "int"), mask 0x\(String(format.channelMask, radix: 16))")
    } catch {
        fail("\(error)")
    }

    let tonesDone = DispatchSemaphore(value: 0)
    if options.has("tones") {
        let id = endpoint?.id
        DispatchQueue.global().async {
            Sleep(200)
            do {
                try AudioLoopback.playTestTones(endpointID: id, milliseconds: Int((seconds - 0.6) * 1000), amplitude: 0.05)
            } catch {
                print("tones: \(error)")
            }
            tonesDone.signal()
        }
    } else {
        tonesDone.signal()
    }
    Sleep(DWORD(seconds * 1000))
    tonesDone.wait()
    loopback.stop()

    let format = loopback.format
    let collected = collector!
    let data = collected.snapshot()
    print("buffers \(collected.buffers) (silent \(collected.silentBuffers), discontinuities \(collected.discontinuities)), idle gaps filled \(collected.gapFrames) frames, \(data.count / max(1, format.bytesPerFrame)) frames total")
    writeWAV(path: path, format: format, data: data)
    print("wrote \(path)")
    if format.isFloat && format.bitsPerSample == 32 { analyse(data: data, format: format) }
}

/// RMS and the strength of each channel's expected test tone, per channel.
func analyse(data: [UInt8], format: AudioLoopback.Format) {
    let channels = format.channels
    let frames = data.count / format.bytesPerFrame
    guard frames > 0 else { return }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
        let samples = raw.bindMemory(to: Float.self)
        print("channel  rms      tone@expected  best-matching tone")
        for channel in 0..<channels {
            var sum = 0.0
            for f in 0..<frames { let s = Double(samples[f * channels + channel]); sum += s * s }
            let rms = (sum / Double(frames)).squareRoot()
            // Goertzel power at each candidate tone; report which one dominates.
            func power(_ hz: Double) -> Double {
                let k = 2 * cos(2 * Double.pi * hz / Double(format.sampleRate))
                var s1 = 0.0, s2 = 0.0
                for f in 0..<frames {
                    let s0 = Double(samples[f * channels + channel]) + k * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(frames * frames)
            }
            let powers = (0..<channels).map { power(250 * Double($0 + 1)) }
            let best = powers.indices.max(by: { powers[$0] < powers[$1] }) ?? 0
            let verdict = best == channel && rms > 1e-4 ? "  ok" : ""
            print(String(format2: "  %2d     %.4f   %10.2e     %d Hz", channel, rms, powers[channel], 250 * (best + 1)) + verdict)
        }
    }
}

func writeWAV(path: String, format: AudioLoopback.Format, data: [UInt8]) {
    guard let file = fopen(path, "wb") else { fail("cannot write \(path)") }
    defer { fclose(file) }
    var header: [UInt8] = []
    func u16(_ v: Int) { header.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    func u32(_ v: Int) { u16(v & 0xFFFF); u16(v >> 16 & 0xFFFF) }
    func tag(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
    // WAVE_FORMAT_EXTENSIBLE keeps the channel mask (which speaker each channel is).
    tag("RIFF"); u32(4 + 8 + 40 + 8 + data.count); tag("WAVE")
    tag("fmt "); u32(40)
    u16(0xFFFE); u16(format.channels); u32(format.sampleRate)
    u32(format.sampleRate * format.bytesPerFrame); u16(format.bytesPerFrame); u16(format.bitsPerSample)
    u16(22); u16(format.bitsPerSample); u32(Int(format.channelMask))
    // Sub-format GUID: KSDATAFORMAT_SUBTYPE_IEEE_FLOAT (3) or _PCM (1).
    u32(format.isFloat ? 3 : 1)
    header.append(contentsOf: [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
    tag("data"); u32(data.count)
    header.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
    data.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
}
