#if DEBUG
import SwiftData
import SwiftUI

/// `-LongwaveScreenshotDemo`: replaces the saved connections with a fixed,
/// plausible set so App Store and review screenshots can be taken in the
/// simulator (`LongwaveUITests/ScreenshotTests`) without real hosts. The store
/// is rewritten on every such launch, so the shots come out identical run to
/// run. Never compiled into a shipped build.
enum ScreenshotDemo {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-LongwaveScreenshotDemo")
    }

    @MainActor
    static func seed(_ context: ModelContext) {
        try? context.delete(model: SavedConnection.self)

        let now = Date()
        let studio = SavedConnection(hostname: "studio-mac.local", port: 7450, label: "Studio Mac", connectionType: .native)
        studio.nativeScreenEnabled = true
        studio.nativeAudioEnabled = true
        studio.lastConnected = now.addingTimeInterval(-60 * 12)

        let server = SavedConnection(hostname: "192.168.1.20", port: 5900, label: "Home Server", connectionType: .vnc)
        server.lastConnected = now.addingTimeInterval(-60 * 60 * 5)

        let build = SavedConnection(hostname: "build-box.local", port: 22, label: "Build Box", connectionType: .ssh)
        build.lastConnected = now.addingTimeInterval(-60 * 60 * 26)

        let laptop = SavedConnection(hostname: "macbook-air.local", port: 7450, label: "MacBook Air", connectionType: .native)
        laptop.nativeScreenEnabled = false
        laptop.nativeAudioEnabled = true
        laptop.lastConnected = now.addingTimeInterval(-60 * 60 * 24 * 3)

        [studio, server, build, laptop].forEach(context.insert)
        try? context.save()
    }
}

private struct ScreenshotDemoSeeder: ViewModifier {
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content.task {
            guard ScreenshotDemo.isActive else { return }
            ScreenshotDemo.seed(modelContext)
        }
    }
}

extension View {
    func screenshotDemo() -> some View {
        modifier(ScreenshotDemoSeeder())
    }
}
#endif
