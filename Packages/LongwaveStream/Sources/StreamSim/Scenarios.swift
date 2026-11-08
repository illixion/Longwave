// Named network scenarios for the stream benches: one model per direction,
// chosen to look like the paths a PCVR stream actually takes. The numbers
// are estimates from public measurements and the headset's own logs, not a
// fit to any one network; they exist so a change can be compared against the
// same bad day every time.

private let ms: UInt64 = 1_000_000
private let s: UInt64 = 1_000_000_000

/// A host → headset path and its reverse.
public struct LinkScenario: Sendable, Equatable {
    public var name: String
    public var summary: String
    /// Host to headset: the media direction.
    public var down: LinkModel
    /// Headset to host: poses, feedback, NACKs.
    public var up: LinkModel

    public init(name: String, summary: String, down: LinkModel, up: LinkModel) {
        self.name = name
        self.summary = summary
        self.down = down
        self.up = up
    }

    /// Megabits per second as the models' bytes per second.
    static func mbps(_ value: Double) -> UInt64 { UInt64(value * 125_000) }

    /// The headset on 5 GHz Wi-Fi 6 a few metres from the access point, the PC
    /// wired to it: ~400 Mbit/s of UDP, a few ms of jitter, rare short loss
    /// bursts, and the headset's own 60–180 ms holds every 20–40 s.
    public static let wifi = LinkScenario(
        name: "wifi", summary: "Wi-Fi 6 in the same room, the headset's measured stalls",
        down: LinkModel(propagationDelay: 2 * ms, jitter: 2 * ms, rate: mbps(400), queueLimit: 1_000_000, loss: 0.002,
                        burst: .init(enterBad: 0.001, leaveBad: 0.3, lossWhenBad: 0.5), stalls: .headset),
        up: LinkModel(propagationDelay: 2 * ms, jitter: 2 * ms, loss: 0.002, stalls: .headset))

    /// `wifi` with AWDL up (AirDrop, Continuity, Mac Virtual Display): the
    /// radio leaves the channel for 20–90 ms every second or two.
    public static let wifiAWDL: LinkScenario = {
        var scenario = wifi
        scenario.name = "wifi-awdl"
        scenario.summary = "wifi plus AWDL trips off channel, 20-90 ms every 0.8-2 s"
        scenario.down.extraStalls = [.awdl]
        scenario.up.extraStalls = [.awdl]
        return scenario
    }()

    /// A crowded channel or the far side of the flat: less rate, more loss,
    /// and spells at 40% when rate adaptation steps down.
    public static let wifiBusy = LinkScenario(
        name: "wifi-busy", summary: "busy or distant Wi-Fi: 160 Mbit/s, fades to 40%, 1% loss",
        down: LinkModel(propagationDelay: 3 * ms, jitter: 5 * ms, rate: mbps(160), queueLimit: 800_000, loss: 0.01,
                        burst: .init(enterBad: 0.003, leaveBad: 0.2, lossWhenBad: 0.6), stalls: .headset,
                        fades: .init(interval: 2 * s...6 * s, duration: 100 * ms...500 * ms, factor: 0.4)),
        up: LinkModel(propagationDelay: 3 * ms, jitter: 5 * ms, loss: 0.01, stalls: .headset))

    /// A GPU instance in AWS eu-north-1 (Stockholm) from a home in the Baltics:
    /// ~12 ms each way over the internet, a 300 Mbit/s downlink with a deep
    /// queue in front of it, internet jitter, and the home Wi-Fi's stalls.
    public static let stockholm = LinkScenario(
        name: "stockholm", summary: "EC2 Stockholm over a 300 Mbit/s home line, then Wi-Fi",
        down: LinkModel(propagationDelay: 12 * ms, jitter: 4 * ms, rate: mbps(300), queueLimit: 2_000_000, loss: 0.002,
                        burst: .init(enterBad: 0.0005, leaveBad: 0.25, lossWhenBad: 0.5), stalls: .headset),
        up: LinkModel(propagationDelay: 12 * ms, jitter: 4 * ms, rate: mbps(50), queueLimit: 500_000, loss: 0.002,
                      stalls: .headset))

    /// `stockholm` with AWDL on the home Wi-Fi.
    public static let stockholmAWDL: LinkScenario = {
        var scenario = stockholm
        scenario.name = "stockholm-awdl"
        scenario.summary = "stockholm plus AWDL trips off channel"
        scenario.down.extraStalls = [.awdl]
        scenario.up.extraStalls = [.awdl]
        return scenario
    }()

    /// `stockholm` through a Tailscale tunnel: datagrams over 1252 bytes vanish.
    public static let stockholmTailscale: LinkScenario = {
        var scenario = stockholm
        scenario.name = "stockholm-tailscale"
        scenario.summary = "stockholm through Tailscale (1252-byte path MTU)"
        scenario.down.maxDatagram = 1252
        scenario.up.maxDatagram = 1252
        return scenario
    }()

    /// Nothing in the way: what the encoder alone does.
    public static let clean = LinkScenario(
        name: "clean", summary: "no loss, no stalls, 1 ms each way",
        down: .lan, up: .lan)

    public static let all: [LinkScenario] = [clean, wifi, wifiAWDL, wifiBusy, stockholm, stockholmAWDL, stockholmTailscale]

    public static func named(_ name: String) -> LinkScenario? {
        all.first { $0.name == name }
    }
}
