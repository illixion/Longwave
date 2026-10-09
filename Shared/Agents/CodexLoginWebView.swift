import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import WebKit

/// Completes Codex's supported ChatGPT browser OAuth flow in an in-app browser.
/// The CLI's registered localhost callback is intercepted before navigation, so
/// no listener is needed and the PKCE verifier stays on this device.
struct CodexLoginSheet: View {
    let onCredential: (CodexOAuth.Credential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pkce = CodexOAuth.BrowserPKCE()
    @State private var isLoading = true
    @State private var currentHost = "auth.openai.com"
    @State private var exchanging = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(currentHost, systemImage: "lock.fill")
                    .font(.callout.monospaced())
                    .foregroundStyle(.green)
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Button("Cancel") { dismiss() }
            }
            .padding()
            Divider()
            ZStack {
                CodexOAuthWebView(
                    url: CodexOAuth.browserAuthorizationURL(pkce: pkce),
                    onCallback: handleCallback,
                    onFailure: { error = $0 },
                    isLoading: $isLoading,
                    currentHost: $currentHost
                )
                if exchanging {
                    Rectangle().fill(.black.opacity(0.4)).overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Completing sign-in…").font(.callout)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 640)
        .platformGlassBackground()
    }

    private func handleCallback(_ callback: (code: String?, state: String?, error: String?)) {
        guard !exchanging else { return }
        if let providerError = callback.error {
            error = "OpenAI sign-in failed: \(providerError)"
            return
        }
        guard let code = callback.code, !code.isEmpty else {
            error = "OpenAI returned no authorization code. Try again."
            return
        }
        exchanging = true
        error = nil
        Task {
            do {
                let credential = try await CodexOAuth.exchangeBrowserCode(
                    code, returnedState: callback.state, pkce: pkce
                )
                onCredential(credential)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                exchanging = false
            }
        }
    }
}

#if canImport(UIKit)
private struct CodexOAuthWebView: UIViewRepresentable {
    let url: URL
    let onCallback: ((code: String?, state: String?, error: String?)) -> Void
    let onFailure: (String) -> Void
    @Binding var isLoading: Bool
    @Binding var currentHost: String

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback, onFailure: onFailure,
                    isLoading: $isLoading, currentHost: $currentHost)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCallback: ((code: String?, state: String?, error: String?)) -> Void
        private let onFailure: (String) -> Void
        @Binding private var isLoading: Bool
        @Binding private var currentHost: String
        private var finished = false

        init(onCallback: @escaping ((code: String?, state: String?, error: String?)) -> Void,
             onFailure: @escaping (String) -> Void,
             isLoading: Binding<Bool>, currentHost: Binding<String>) {
            self.onCallback = onCallback
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
            if let callback = CodexOAuth.browserCallback(from: url), !finished {
                finished = true
                decisionHandler(.cancel)
                isLoading = false
                onCallback(callback)
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

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            onFailure(error.localizedDescription)
        }
    }
}
#else
private struct CodexOAuthWebView: NSViewRepresentable {
    let url: URL
    let onCallback: ((code: String?, state: String?, error: String?)) -> Void
    let onFailure: (String) -> Void
    @Binding var isLoading: Bool
    @Binding var currentHost: String

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback, onFailure: onFailure,
                    isLoading: $isLoading, currentHost: $currentHost)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCallback: ((code: String?, state: String?, error: String?)) -> Void
        private let onFailure: (String) -> Void
        @Binding private var isLoading: Bool
        @Binding private var currentHost: String
        private var finished = false

        init(onCallback: @escaping ((code: String?, state: String?, error: String?)) -> Void,
             onFailure: @escaping (String) -> Void,
             isLoading: Binding<Bool>, currentHost: Binding<String>) {
            self.onCallback = onCallback
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
            if let callback = CodexOAuth.browserCallback(from: url), !finished {
                finished = true
                decisionHandler(.cancel)
                isLoading = false
                onCallback(callback)
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

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure(error.localizedDescription)
        }
    }
}
#endif
