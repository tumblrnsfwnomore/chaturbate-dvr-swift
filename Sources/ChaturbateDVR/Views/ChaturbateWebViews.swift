import SwiftUI
import WebKit

struct ChaturbateLoginSheet: View {
    @ObservedObject var manager: ChannelManager
    @Binding var isPresented: Bool
    @State private var statusMessage: String = "Sign in using the page below."
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to Chaturbate")
                        .font(.headline)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving session...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ChaturbateLoginWebView { cookies, userAgent, username in
                guard !isSaving else { return }
                isSaving = true
                statusMessage = "Saving authenticated session..."
                Task { @MainActor in
                    manager.setInAppSession(cookies: cookies, userAgent: userAgent, username: username)
                    isPresented = false
                }
            }
        }
        .frame(minWidth: 1020, minHeight: 700)
    }
}

private struct ChaturbateLoginWebView: NSViewRepresentable {
    let onAuthenticated: (_ cookies: [String: String], _ userAgent: String, _ username: String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    // A realistic Safari UA — passes Chaturbate's browser-version gate
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.attach(webView)

        if let url = URL(string: "https://chaturbate.com/auth/login/") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: ([String: String], String, String?) -> Void
        private weak var webView: WKWebView?
        private var didCapture = false

        init(onAuthenticated: @escaping ([String: String], String, String?) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectAuthenticationIfNeeded(webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            inspectAuthenticationIfNeeded(webView)
        }

        private func inspectAuthenticationIfNeeded(_ webView: WKWebView) {
            guard !didCapture else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !self.didCapture else { return }

                let domainCookies = cookies.filter { $0.domain.contains("chaturbate.com") }
                let cookieMap = Dictionary(uniqueKeysWithValues: domainCookies.map { ($0.name, $0.value) })
                let hasSession = !(cookieMap["sessionid"] ?? "").isEmpty
                let hasCSRF = !(cookieMap["csrftoken"] ?? "").isEmpty

                guard hasSession, hasCSRF else { return }

                self.didCapture = true

                webView.evaluateJavaScript("navigator.userAgent") { userAgentResult, _ in
                    let userAgent = userAgentResult as? String ?? ""
                    webView.evaluateJavaScript(Self.usernameExtractionScript) { usernameResult, _ in
                        let extracted = (usernameResult as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let usernameFromCookie = cookieMap["username"]
                        let username = (extracted?.isEmpty == false ? extracted : usernameFromCookie)
                        self.onAuthenticated(cookieMap, userAgent, username)
                    }
                }
            }
        }

        private static let usernameExtractionScript = #"""
(() => {
  const clean = (value) => {
    if (!value) return "";
    return String(value).trim().replace(/^@/, "");
  };

  const selectors = [
    '[data-testid="nav-username"]',
    '[data-test="nav-username"]',
    '[data-qa="username"]',
    'a[href^="/u/"]',
    'a[href^="/users/"]',
    'a[href^="/@"]'
  ];

  for (const selector of selectors) {
    const node = document.querySelector(selector);
    const value = clean(node && node.textContent);
    if (value) return value;
  }

  const storageKeys = ['username', 'user_name', 'cb_username'];
  for (const key of storageKeys) {
    const localVal = clean(window.localStorage && window.localStorage.getItem(key));
    if (localVal) return localVal;
    const sessionVal = clean(window.sessionStorage && window.sessionStorage.getItem(key));
    if (sessionVal) return sessionVal;
  }

  return "";
})();
"""#
    }
}

struct ChaturbateChannelPageSheet: View {
    let username: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Channel Page")
                        .font(.headline)
                    Text("@\(username)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ChaturbatePageWebView(urlString: "https://chaturbate.com/\(username)")
        }
        .frame(minWidth: 1040, minHeight: 720)
    }
}

private struct ChaturbatePageWebView: NSViewRepresentable {
    let urlString: String

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let currentURL = nsView.url?.absoluteString, currentURL == urlString else {
            if let url = URL(string: urlString) {
                nsView.load(URLRequest(url: url))
            }
            return
        }
    }
}
