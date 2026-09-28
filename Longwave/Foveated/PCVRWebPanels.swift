//
//  PCVRWebPanels.swift
//  Longwave
//
//  Web pages pinned in the PCVR space, OVR Toolkit style: Twitch chat on the back of
//  the wrist, or a page pinned to a spot in your view. They are view-only while you
//  play. The palm HUD switches them all into touch mode (use the page: scroll, sign
//  in, type in chat) or move mode (drag them around, resize), and a Done button on
//  the panel switches back. Both modes keep your pinches from the game, which is why
//  the switch lives on the palm HUD: it already does, so pressing it cannot leak a
//  pinch into the game.
//
//  PCVR only: anywhere else, a Safari window does the job.
//
//  The panel in the room is RAVEEngine's `RAVEPanel` (wrist mount, view lock, pausing
//  verdict); the web view host is RAVESDK's `RAVEWebViewHost`, which pauses a page by
//  taking it out of its window, the one thing WebKit treats as hidden. A page nobody
//  can see (wrist turned away, panel out of view) stops rendering.
//
//  Gated behind FOVEATED_ENABLED.
//

#if FOVEATED_ENABLED
import Foundation
import Observation
import WebKit

/// One pinned page.
struct PCVRWebPanelConfig: Codable, Identifiable, Equatable {
    enum Mount: String, Codable, CaseIterable, Identifiable {
        case leftWrist, rightWrist, view
        var id: String { rawValue }
        var label: String {
            switch self {
            case .leftWrist: "Left wrist"
            case .rightWrist: "Right wrist"
            case .view: "In view"
            }
        }
    }

    var id = UUID()
    var address: String
    var mount: Mount = .leftWrist
    var enabled = true
    /// 0.3…1: the page shows the game through it.
    var opacity: Double = 0.9
    /// Width in metres; the height follows the page's layout shape.
    var widthMeters: Float = 0.2
    /// Where it sits relative to its mount (hand or head frame), once moved by hand.
    /// Nil for the mount's default.
    var offset: [Float]?

    /// The page's layout size, in points. Narrow, so chat and most sites serve
    /// their phone layout.
    static let layoutPoints = CGSize(width: 360, height: 480)

    var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
    }

    /// Twitch's pop-out chat for a channel: the whole point of a wrist panel.
    static func twitchChat(channel: String) -> String {
        "https://www.twitch.tv/popout/\(channel.trimmingCharacters(in: .whitespaces).lowercased())/chat?popout="
    }
}

/// What the pinned pages are doing: shown for reading, or taking input.
enum PCVRWebPanelMode: String {
    /// Read only. No input reaches the page, and your pinches go to the game.
    case view
    /// Use the page. Pinches stay out of the game.
    case touch
    /// Drag the panels by their grab bar and resize them by the corner.
    case move
}

/// The pinned pages, their mode, and the one web profile they share.
@MainActor
@Observable
final class PCVRWebPanelStore {
    static let shared = PCVRWebPanelStore()
    private static let key = "foveatedWebPanels"

    private(set) var panels: [PCVRWebPanelConfig]
    var mode: PCVRWebPanelMode = .view

    /// One persistent profile for every pinned page, apart from any other web view in
    /// the app: sign in to Twitch once in touch mode and every chat panel can type.
    static let profileID = UUID(uuidString: "8429512F-5D4E-435E-B444-4159EE91DF0D")!
    static var dataStore: WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: profileID) }

    private init() {
        panels = Self.load(from: UserDefaults.standard)
    }

    static func load(from defaults: UserDefaults) -> [PCVRWebPanelConfig] {
        guard let data = defaults.data(forKey: key),
              let panels = try? JSONDecoder().decode([PCVRWebPanelConfig].self, from: data) else { return [] }
        return panels
    }

    /// For backups: the raw blob, so `LongwaveBackup` needs no FOVEATED types.
    static var savedData: Data? { UserDefaults.standard.data(forKey: key) }
    static func restore(_ data: Data) {
        UserDefaults.standard.set(data, forKey: key)
        shared.panels = load(from: .standard)
    }

    var hasEnabledPanels: Bool { panels.contains { $0.enabled && $0.url != nil } }

    func add(_ panel: PCVRWebPanelConfig) {
        panels.append(panel)
        save()
    }

    func update(_ panel: PCVRWebPanelConfig) {
        guard let index = panels.firstIndex(where: { $0.id == panel.id }) else { return }
        panels[index] = panel
        save()
    }

    func remove(_ id: UUID) {
        panels.removeAll { $0.id == id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(panels) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

/// A pinned page's web view, owned for the whole time the space is open so pausing
/// (moving it out of its window) never reloads it.
@MainActor
@Observable
final class PCVRWebPanelPage {
    let id: UUID
    let webView: WKWebView
    /// Out of its window, so WebKit stops it: set each frame from the panel's verdict.
    var isPaused = false

    init(config: PCVRWebPanelConfig) {
        id = config.id
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = PCVRWebPanelStore.dataStore
        configuration.allowsInlineMediaPlayback = true
        // Never at zero size: WebKit fits its zoom to the view, a zoom fitted to 0×0 is
        // NaN, and CALayer throws on it (seen in spatial-ai-character, 2026-09-28).
        let view = WKWebView(frame: CGRect(origin: .zero, size: PCVRWebPanelConfig.layoutPoints),
                             configuration: configuration)
        // Transparent where the page is, so a page without a background of its own
        // sits on the panel's glass rather than a white slab.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        webView = view
        if let url = config.url { view.load(URLRequest(url: url)) }
    }
}
#endif
