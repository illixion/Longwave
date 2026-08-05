import SwiftUI
import UIKit
import WebKit

/// Holds the live web view so the sheet can drive it — inject a pasted code, or
/// follow a magic link — without the SwiftUI layer owning UIKit state.
@MainActor
final class ClaudeLoginController {
    fileprivate weak var webView: WKWebView?

    /// Types `code` into the sign-in form.
    ///
    /// Setting `.value` directly wouldn't stick: the page is React, which tracks
    /// input state internally and would overwrite a raw assignment on its next
    /// render. Going through the native property setter and then dispatching
    /// `input`/`change` is what makes React observe the edit as if it were typed.
    func paste(code: String) {
        guard let webView else { return }
        let escaped = code
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(code){
          var el = document.activeElement;
          if (!el || el.tagName !== 'INPUT') {
            el = Array.prototype.slice.call(document.querySelectorAll('input'))
              .filter(function(i){
                return i.offsetParent !== null && !i.disabled && i.type !== 'hidden';
              })[0];
          }
          if (!el) { return 'no-input'; }
          el.focus();
          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value').set;
          setter.call(el, code);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })('\(escaped)');
        """
        webView.evaluateJavaScript(js)
    }

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
}

/// An in-app browser that hosts Claude's OAuth consent page and captures the
/// authorization code the moment it's issued.
///
/// The whole point of embedding the browser rather than handing the URL to Safari
/// is that the redirect target is `http://localhost:3118/callback` — a loopback
/// address the CLI listens on and this app does not. Owning the web view means the
/// navigation delegate sees that redirect *before* the request is made, so the
/// code is read straight out of the URL and the navigation cancelled. No local
/// listener, no port to open, and no copy-paste step for the user.
///
/// Cookies use a **non-persistent** data store, so the claude.ai session
/// established to approve this grant is discarded with the sheet and never
/// written to the app container. The credential this flow produces is the only
/// thing that persists, and only in the keychain.
private struct ClaudeOAuthWebView: UIViewRepresentable {
    let url: URL
    let controller: ClaudeLoginController
    /// Called once, on the main actor, with the intercepted code and state.
    let onCode: (String, String?) -> Void
    let onFailure: (Error) -> Void
    /// Mirrors load progress and the live origin back out for the chrome.
    @Binding var isLoading: Bool
    @Binding var currentHost: String

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure,
                    isLoading: $isLoading, currentHost: $currentHost)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Identify as desktop Safari. Federated identity providers commonly
        // refuse to render a sign-in form inside an unrecognized embedded web
        // view, which would strand anyone whose Claude account uses SSO; this is
        // the standard compatibility shim for a first-party in-app login.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        controller.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCode: (String, String?) -> Void
        private let onFailure: (Error) -> Void
        @Binding private var isLoading: Bool
        @Binding private var currentHost: String
        /// The flow ends exactly once; a redirect chain must not fire it twice.
        private var finished = false

        init(onCode: @escaping (String, String?) -> Void,
             onFailure: @escaping (Error) -> Void,
             isLoading: Binding<Bool>, currentHost: Binding<String>) {
            self.onCode = onCode
            self.onFailure = onFailure
            _isLoading = isLoading
            _currentHost = currentHost
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if let (code, state) = ClaudeOAuth.authCode(from: url), !finished {
                // Cancel rather than allow: the loopback URL has nothing serving
                // it, so letting this proceed would only render a connection
                // error over a flow that already succeeded.
                finished = true
                decisionHandler(.cancel)
                isLoading = false
                onCode(code, state)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            if let host = webView.url?.host { currentHost = host }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            if let host = webView.url?.host { currentHost = host }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            guard !finished else { return }
            onFailure(error)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            isLoading = false
            // A cancelled provisional load is the normal result of intercepting
            // the redirect, not a failure worth reporting.
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure(error)
        }
    }
}

/// What the clipboard appears to be offering, so the affordance can be labelled
/// before anything is actually read.
private enum ClipboardOffer: Equatable {
    case code
    case link
    case unknown

    var label: String {
        switch self {
        case .code: "Paste Code"
        case .link: "Open Sign-in Link"
        case .unknown: "Paste from Clipboard"
        }
    }

    var icon: String {
        switch self {
        case .code: "doc.on.clipboard"
        case .link: "link"
        case .unknown: "doc.on.clipboard"
        }
    }
}

/// The sheet wrapper: chrome around the embedded browser, plus the exchange.
///
/// Shows the live origin next to a lock, because this is a window asking for
/// someone's Claude password — being able to confirm at a glance that the page
/// really is on `claude.com` is the difference between a trustworthy in-app login
/// and one that merely looks like the real thing.
///
/// ### Why the clipboard is watched
///
/// Claude signs in by emailing a code *and* a magic link. Neither arrives in this
/// web view: the link opens in Safari, which has its own cookie jar, so following
/// it there logs the user in somewhere this sheet can't see and the flow stalls on
/// a consent page that never advances. Whichever one the user copies out of Mail,
/// this brings it back here — a code gets typed into the form, a link gets loaded
/// in *this* web view so the session lands where the grant is being approved.
///
/// The clipboard is never read on its own. Only `changeCount` is polled (a
/// counter, not content) and `detectPatterns` classifies without disclosing;
/// reading happens when the user taps, which is also what makes the system's
/// paste notification expected rather than alarming.
struct ClaudeLoginSheet: View {
    /// Called with the minted credential; the caller decides where it goes.
    let onCredential: (ClaudeOAuth.Credential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pkce = ClaudeOAuth.PKCE()
    @State private var controller = ClaudeLoginController()
    @State private var isLoading = true
    @State private var currentHost = "claude.com"
    @State private var exchanging = false
    @State private var error: String?

    // Clipboard assist.
    @State private var offer: ClipboardOffer?
    @State private var lastChangeCount = UIPasteboard.general.changeCount

    var body: some View {
        VStack(spacing: 0) {
            header
            if offer != nil { clipboardBar }
            Divider()
            ZStack {
                ClaudeOAuthWebView(
                    url: ClaudeOAuth.authorizeURL(pkce: pkce),
                    controller: controller,
                    onCode: { code, state in exchange(code: code, state: state) },
                    onFailure: { error = $0.localizedDescription },
                    isLoading: $isLoading,
                    currentHost: $currentHost
                )
                if exchanging {
                    // Cover the browser while the code is redeemed, so a stale
                    // consent page can't be interacted with mid-exchange.
                    Rectangle()
                        .fill(.black.opacity(0.4))
                        .overlay {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Completing sign-in…").font(.callout)
                            }
                        }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .glassBackgroundEffect()
        .task { await watchClipboard() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label {
                Text(currentHost).font(.callout.monospaced())
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(.green)
            }
            if isLoading { ProgressView().controlSize(.small) }
            Spacer()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Button("Cancel") { dismiss() }
        }
        .padding()
    }

    /// Appears only once something new is on the clipboard, so it reads as "your
    /// code is ready" rather than as permanent chrome.
    @ViewBuilder
    private var clipboardBar: some View {
        if let offer {
            HStack(spacing: 12) {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(.secondary)
                Text("Copied from Mail?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    useClipboard()
                } label: {
                    Label(offer.label, systemImage: offer.icon)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    self.offer = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Clipboard

    /// Polls the pasteboard's change *counter* while the sheet is open. The
    /// counter carries no content, so this discloses nothing and raises no paste
    /// notification; classification is delegated to `detectPatterns`, which is
    /// also non-disclosing.
    private func watchClipboard() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let pasteboard = UIPasteboard.general
            let count = pasteboard.changeCount
            guard count != lastChangeCount else { continue }
            lastChangeCount = count
            offer = await classifyClipboard(pasteboard)
        }
    }

    private func classifyClipboard(_ pasteboard: UIPasteboard) async -> ClipboardOffer {
        let patterns = await Self.detectedPatterns(pasteboard)
        if patterns.contains(.probableWebURL) { return .link }
        if patterns.contains(.number) { return .code }
        // Detection can come back empty for short opaque strings; still offer it,
        // since the user copied *something* while a login sheet was open.
        return .unknown
    }

    /// `detectPatterns` is refined for Swift by hand, so UIKit ships only
    /// completion-handler overloads — there's no async version to await. The set
    /// is explicitly typed because the key-path overload otherwise makes the
    /// literal ambiguous. Failures collapse to "nothing detected", which just
    /// means the affordance falls back to a generic label.
    private static func detectedPatterns(
        _ pasteboard: UIPasteboard
    ) async -> Set<UIPasteboard.DetectionPattern> {
        let requested: Set<UIPasteboard.DetectionPattern> = [.probableWebURL, .number]
        return await withCheckedContinuation { continuation in
            pasteboard.detectPatterns(for: requested) { result in
                continuation.resume(returning: (try? result.get()) ?? [])
            }
        }
    }

    /// Reads the clipboard (user-initiated) and routes it: a Claude URL is loaded
    /// in this web view, anything else is typed into the form as a code.
    private func useClipboard() {
        guard let raw = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            offer = nil
            return
        }
        offer = nil
        if let url = URL(string: raw), Self.isClaudeSignInURL(url) {
            controller.load(url)
            return
        }
        // Strip spacing that mail clients add to long codes; keep it otherwise
        // verbatim so a non-numeric token still goes through.
        controller.paste(code: raw.replacingOccurrences(of: " ", with: ""))
    }

    /// Only Claude's own hosts are ever loaded from the clipboard — following an
    /// arbitrary copied URL inside a window the user is treating as Claude's
    /// sign-in page is exactly the confusion this sheet's lock icon is meant to
    /// prevent.
    static func isClaudeSignInURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else { return false }
        let allowed = ["claude.ai", "claude.com", "platform.claude.com"]
        return allowed.contains(host) || allowed.contains { host.hasSuffix(".\($0)") }
    }

    private func exchange(code: String, state: String?) {
        exchanging = true
        error = nil
        Task {
            do {
                // Takes the server's default lifetime — requesting a custom one
                // is rejected for this scope set (see `ClaudeOAuth.Constants`).
                let credential = try await ClaudeOAuth.exchange(
                    code: code, pkce: pkce, returnedState: state
                )
                onCredential(credential)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                exchanging = false
            }
        }
    }
}
