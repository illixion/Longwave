#if os(visionOS)
import SwiftUI

/// The plumbing behind the "Dictate" button a keyboard window offers: the
/// recognizer, and the record of how much of this run has already gone out.
///
/// Only *settled* phrases are forwarded, and only their new tail. The recognizer
/// keeps revising the phrase it is still hearing, so mirroring
/// `DictationController.transcript` would reach the remote as backspace-and-retype
/// churn.
@MainActor
@Observable
final class DictationRelay {
    /// In-app dictation, so typing by voice into a remote doesn't depend on the
    /// system keyboard's dictation session (see `DictationController`).
    private let controller = DictationController()

    /// How much of this run has already been typed onto the remote.
    private var sentSoFar = ""

    var isListening: Bool { controller.isListening }
    var isBusy: Bool { controller.isBusy }

    /// What a view watches; hand every change to `newText(in:)`.
    var settledTranscript: String { controller.settledTranscript }

    var note: String? {
        switch controller.status {
        case .preparing: return "Preparing dictation…"
        case .listening: return "Listening — words are typed as each phrase settles."
        case .unavailable(let reason), .failed(let reason): return reason
        case .idle: return nil
        }
    }

    func toggle() async {
        if controller.isListening {
            await controller.stop()
            return
        }
        sentSoFar = ""
        await controller.start()
    }

    func cancel() async {
        await controller.cancel()
        sentSoFar = ""
    }

    /// Whatever is new since the last settled transcript. Settled text only ever
    /// grows within a run; anything else means the session restarted or was
    /// cancelled, so resync silently rather than backspacing the remote.
    func newText(in transcript: String) -> String? {
        guard transcript.hasPrefix(sentSoFar) else {
            sentSoFar = transcript
            return nil
        }
        let tail = String(transcript.dropFirst(sentSoFar.count))
        sentSoFar = transcript
        return tail.isEmpty ? nil : tail
    }
}

/// The dictate toggle, plus the wiring that turns settled speech into typed text.
/// Pair it with a `DictationNote` somewhere below the keys — the button is in a
/// row of controls, the status line gets its own line.
struct DictationButton: View {
    let relay: DictationRelay
    /// Whether the transport can carry literal text at all right now. Native's
    /// channels come and go, so an unusable button is disabled rather than
    /// silently inert.
    var isEnabled: Bool = true
    /// Where dictated text goes.
    let insert: (String) -> Void

    var body: some View {
        Button {
            Task { await relay.toggle() }
        } label: {
            Label(relay.isListening ? "Stop" : "Dictate",
                  systemImage: relay.isListening ? "mic.fill" : "mic")
        }
        .buttonStyle(.bordered)
        .tint(relay.isListening ? .red : nil)
        // A channel that drops mid-session must still leave a way to stop
        // listening, so only an idle button follows `isEnabled`.
        .disabled(relay.isBusy || (!isEnabled && !relay.isListening))
        .help(relay.isListening ? "Stop dictating" : "Dictate text to the remote desktop")
        .onDisappear {
            Task { await relay.cancel() }
        }
        .onChange(of: relay.settledTranscript) { _, transcript in
            guard let tail = relay.newText(in: transcript) else { return }
            insert(tail)
        }
    }
}

/// The dictation status line: progress and failures, since the button itself only
/// has room for its own state.
struct DictationNote: View {
    let relay: DictationRelay

    var body: some View {
        if let note = relay.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(relay.isListening ? Color.secondary : Color.orange)
        }
    }
}
#endif
