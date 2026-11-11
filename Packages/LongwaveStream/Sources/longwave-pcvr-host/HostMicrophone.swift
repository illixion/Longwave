// The headset's microphone on the PC (capability `microphone`): samples from
// a PCVR viewer's audio shards play into a virtual audio cable's render
// endpoint, whose capture side a game or voice app picks as its microphone.
// It replaces what CloudXR's own virtual audio driver did for its sessions.
//
// One headset at a time: the newest to send a format owns the device. The
// playback opens on the viewer's `microphoneFormat` and closes when it says it
// stopped, leaves, or goes quiet for `idleClose`.
//
// Network-thread methods run under the host's lock; the render callback runs
// on the shim's audio thread and only touches the playout (its own lock).

import Foundation
import StreamHostWindows
import StreamPlayout
import StreamWire

final class HostMicrophone: @unchecked Sendable {
    /// Render endpoints tried in order when `--mic-device` isn't given: the
    /// installed virtual cables (VAC's "Line 1 (Virtual Audio Cable)",
    /// VB-Audio's "CABLE Input").
    static let defaultDeviceNames = ["Virtual Audio Cable", "CABLE Input", "VB-Audio"]
    /// No samples for this long and the playback closes (a headset that left
    /// without saying so); the next format or shard opens it again.
    static let idleClose: UInt64 = 5_000_000_000

    let endpoint: AudioLoopback.Endpoint
    private let log: HostLog
    private var render: AudioRender?
    private var playout: MicrophonePlayout?
    private var owner: UInt32?
    private var ownerName = ""
    private var format: MicrophoneFormat?
    private var lastAudio: UInt64 = 0
    private var lastHealthLog: UInt64 = 0
    private var packets = 0

    /// The endpoint for `option` (`--mic-device`): nil for "off", a name to
    /// match, or the defaults when nil.
    static func make(option: String?, log: HostLog) -> HostMicrophone? {
        if option?.lowercased() == "off" {
            log.line("microphone: off (--mic-device off)")
            return nil
        }
        let names = option.map { [$0] } ?? defaultDeviceNames
        guard let endpoint = AudioRender.endpoint(matching: names) else {
            log.line("microphone: no render endpoint matching \(names.joined(separator: " / ")); "
                     + "headsets won't be offered the microphone (install a virtual cable, or pass --mic-device)")
            return nil
        }
        log.line("microphone: headset voice plays into '\(endpoint.name)'; pick its capture side as the microphone")
        return HostMicrophone(endpoint: endpoint, log: log)
    }

    private init(endpoint: AudioLoopback.Endpoint, log: HostLog) {
        self.endpoint = endpoint
        self.log = log
    }

    /// `microphoneFormat` from a viewer.
    func format(_ format: MicrophoneFormat, from viewer: UInt32, name: String) {
        if format.isStopped {
            guard owner == viewer else { return }
            log.line("microphone: '\(name)' stopped")
            close()
            return
        }
        if owner == viewer, self.format == format, render != nil { return }
        close()
        let playout = MicrophonePlayout(sampleRate: Int(format.sampleRate))
        do {
            render = try AudioRender(endpointID: endpoint.id, sampleRate: Int(format.sampleRate)) { buffer in
                playout.render(into: buffer)
            }
        } catch {
            log.line("microphone: couldn't open '\(endpoint.name)': \(error)")
            return
        }
        self.playout = playout
        self.format = format
        owner = viewer
        ownerName = name
        packets = 0
        lastAudio = Self.now()
        log.line("microphone: '\(name)' at \(format.sampleRate) Hz into '\(endpoint.name)'")
    }

    /// An audio shard from a viewer.
    func audio(_ header: AudioShardHeader, packet: ArraySlice<UInt8>, from viewer: UInt32) {
        guard viewer == owner, let playout, header.codec == .pcm24, header.channelID == 0, !header.isParity else { return }
        playout.receive(firstSample: header.firstSample, discontinuity: header.discontinuity,
                        samples: MicrophoneAudio.decode(packet))
        packets += 1
        lastAudio = Self.now()
    }

    func viewerLeft(_ viewer: UInt32) {
        guard owner == viewer else { return }
        log.line("microphone: '\(ownerName)' left")
        close()
    }

    /// From the network thread's periodic work: closes an idle playback and
    /// logs the cushion's health now and then.
    func tick(now: UInt64) {
        guard let playout else { return }
        if now &- lastAudio > Self.idleClose {
            log.line("microphone: nothing from '\(ownerName)' for \(Self.idleClose / 1_000_000_000) s, closing")
            close()
            return
        }
        guard now &- lastHealthLog > 10_000_000_000 else { return }
        lastHealthLog = now
        let h = playout.takeHealth()
        log.line(String(format: "microphone: %d packets, cushion %.0f ms (target %.0f), %d underruns, %d lost, %d late, %d trimmed",
                        packets, h.bufferedSeconds * 1000, h.targetSeconds * 1000, h.underruns, h.lostFrames,
                        h.latePackets, h.trimmedFrames))
        packets = 0
    }

    func close() {
        render?.stop()
        render = nil
        playout = nil
        format = nil
        owner = nil
    }

    private static func now() -> UInt64 { HostClock.nanoseconds(HostClock.now()) }
}
