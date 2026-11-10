//
//  SupportWelcome.swift
//  Longwave
//
//  Attaches RAVESupport's one-time sponsor sheet to a platform's root view.
//  On visionOS PCVR builds the sheet is held back while a PCVR session is
//  connecting, streaming or paused, so it can never cover a stream.
//

import RAVESupport
import SwiftUI

extension RAVESupportConfig {
    /// The Longwave card; the bundle id keys "already shown", so the three
    /// editions (and each platform's app) track it independently.
    static var longwave: RAVESupportConfig {
        RAVESupportConfig(appName: "Longwave", appID: Bundle.main.bundleIdentifier ?? "pro.longwave.ios")
    }
}

extension View {
    /// Root-view modifier: the welcome sheet, only ever in the normal window.
    func longwaveSupportWelcome() -> some View {
        #if os(visionOS) && FOVEATED_ENABLED
        modifier(PCVRAwareSupportWelcome())
        #else
        raveSupportWelcome(.longwave)
        #endif
    }
}

#if os(visionOS) && FOVEATED_ENABLED
private struct PCVRAwareSupportWelcome: ViewModifier {
    @Environment(FoveatedConnectionManager.self) private var foveated: FoveatedConnectionManager?

    func body(content: Content) -> some View {
        // A background host keeps `content`'s identity stable when the gate flips.
        content.background {
            if foveated.map({ $0.isDisconnected && !$0.isStreaming }) ?? true {
                Color.clear.raveSupportWelcome(.longwave)
            }
        }
    }
}
#endif
