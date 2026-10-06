import SwiftUI

@main
struct LongwaveWatchApp: App {
    @State private var hosts = WatchHostStore()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environment(hosts)
        }
    }
}
