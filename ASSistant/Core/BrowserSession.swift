import Foundation
import WebKit
import SwiftUI

struct BrowserElement: Identifiable, Equatable {
    var id: String
    var text: String
    var href: String
    var kind: String
}

enum BrowserFailure: LocalizedError {
    case badURL, busy, unavailable, userTookControl, navigationTimedOut, invalidLink
    var errorDescription: String? {
        switch self {
        case .badURL: return "Only public HTTPS websites can be opened by the autonomous browser."
        case .busy: return "A browser navigation is already running."
        case .unavailable: return "This page could not be read. It may require login, JavaScript interaction, or block automation."
        case .userTookControl: return "Browsing paused because you took control."
        case .navigationTimedOut: return "The page didn't finish loading."
        case .invalidLink: return "The selected link is unavailable or unsafe."
        }
    }
}

/// One shared, real WKWebView for human and agent use.
/// Unlike the uploaded desktop Python/Playwright script, this runs on iOS 16.
/// It exposes bounded page text and clickable links, not unrestricted JS execution.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    @Published var visible = false
    @Published var expanded = false
    @Published var userControl = false
    @Published var isLoading = false
    @Published var currentURL = ""
    @Published var title = "Browser"
    @Published var pageText = ""
    @Published var links: [BrowserElement] = []
    @Published var status = "Ready"
    @Published var lastError = ""
    @Published var progress: Double = 0

    private var pending: CheckedContinuation<Void, Error>?
    private var navigationSequence = 0

    override init() {
        let config = WKWebViewConfiguration()
        // Ephemeral cookies: a user may log in while taking control, but the
        // assistant must not gain persistent access to Safari account cookies.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."),
              host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.hasSuffix(".test"), !host.hasSuffix(".invalid"),
              !host.contains(":"),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil
        else { return nil }
        return url
    }

    func search(_ query: String, site: String? = nil) async throws -> String {
        let trimmed = String(query.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserFailure.badURL }
        let domain = (site ?? "").lowercased()
        let specificSite = domain == "amazon" || domain == "amazon.com" ? "site:amazon.com " : ""
        let terms = specificSite + trimmed
        var parts = URLComponents(string: "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: terms)]
        guard let url = parts.url else { throw BrowserFailure.badURL }
        return try await navigate(url.absoluteString)
    }

    func navigate(_ raw: String) async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        guard let url = Self.safeURL(raw) else { throw BrowserFailure.badURL }
        guard pending == nil else { throw BrowserFailure.busy }
        visible = true
        expanded = false
        status = "Opening " + (url.host ?? "website")
        lastError = ""
        navigationSequence += 1
        let sequence = navigationSequence
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending = continuation
            guard web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                      timeoutInterval: 24)) != nil else {
                pending = nil
                continuation.resume(throwing: BrowserFailure.unavailable)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, self.navigationSequence == sequence, let waiter = self.pending else { return }
                self.pending = nil
                waiter.resume(throwing: BrowserFailure.navigationTimedOut)
            }
        }
        return try await read()
    }

    func followLink(_ id: String) async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        guard let link = links.first(where: { $0.id == id }),
              let url = Self.safeURL(link.href) else { throw BrowserFailure.invalidLink }
        return try await navigate(url.absoluteString)
    }

    func read() async throws -> String {
        visible = true
        // Intentionally never copy input values, passwords, cookies, form
        // contents, or page-local storage into the model context.
        let js = #"""
        (() => {
          const els = [...document.querySelectorAll('a[href]')].filter(e => {
            const r=e.getBoundingClientRect();
            const style=getComputedStyle(e);
            return r.width>0 && r.height>0 && style.visibility!=='hidden';
          }).slice(0,85);
          const links=els.map((e,i)=>{
            const id='L'+(i+1);
            e.dataset.assistantLink=id;
            return {id:id,kind:'link',
              text:(e.innerText||e.getAttribute('aria-label')||e.title||'').trim().slice(0,140),
              href:e.href||''};
          }).filter(e=>e.href.startsWith('https://'));
          const roots=[document.querySelector('main'),document.querySelector('article'),document.body].filter(Boolean);
          const text=roots.map(e=>e.innerText||'').sort((a,b)=>b.length-a.length)[0]||'';
          return {url:location.href,title:document.title||'',text:text.slice(0,20000),links:links};
        })()
        """#
        do {
            let value = try await web.evaluateJavaScript(js)
            guard let state = value as? [String: Any] else { throw BrowserFailure.unavailable }
            currentURL = (state["url"] as? String) ?? web.url?.absoluteString ?? ""
            title = (state["title"] as? String) ?? "Website"
            pageText = (state["text"] as? String) ?? ""
            links = ((state["links"] as? [[String: String]]) ?? []).map {
                BrowserElement(id: $0["id"] ?? "", text: $0["text"] ?? "",
                               href: $0["href"] ?? "", kind: "link")
            }
            status = "Page ready"
            var result = "PAGE: " + title + "\nURL: " + currentURL + "\n\n"
            result += String(pageText.prefix(11500)) + "\n\nLINKS:\n"
            result += links.prefix(55).map { "\($0.id) \($0.text): \($0.href)" }.joined(separator: "\n")
            return String(result.prefix(17500))
        } catch {
            lastError = error.localizedDescription
            throw BrowserFailure.unavailable
        }
    }

    func close() {
        visible = false
        expanded = false
        userControl = false
    }

    func stop() {
        web.stopLoading()
        if let waiter = pending {
            pending = nil
            waiter.resume(throwing: CancellationError())
        }
        status = "Stopped"
        isLoading = false
    }

    func goBack() {
        if web.canGoBack { web.goBack() }
    }

    func reload() { web.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        progress = 0.15
        status = "Loading website…"
        currentURL = webView.url?.absoluteString ?? currentURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        currentURL = webView.url?.absoluteString ?? currentURL
        title = webView.title ?? title
        if let waiter = pending {
            pending = nil
            waiter.resume()
        }
        Task { @MainActor [weak self] in _ = try? await self?.read() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error) {
        isLoading = false
        lastError = error.localizedDescription
        status = "Page load failed"
        if let waiter = pending {
            pending = nil
            waiter.resume(throwing: error)
        }
    }

    // Keep ordinary browsing inside the same view and reject unsupported URL schemes.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        decisionHandler(Self.safeURL(url.absoluteString) != nil ? .allow : .cancel)
    }
}

struct BrowserSurface: UIViewRepresentable {
    @ObservedObject var session: BrowserSession
    func makeUIView(context: Context) -> WKWebView { session.web }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

/// Compact live page in chat; tap it to expand and take over the real browser.
/// It deliberately uses the SAME WKWebView instance as the agent.
struct BrowserDock: View {
    @ObservedObject var session: BrowserSession
    @State private var appear = false

    var body: some View {
        if session.visible {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundColor(.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title.isEmpty ? "Live browser" : session.title)
                            .font(.caption).fontWeight(.semibold).lineLimit(1)
                        Text(session.userControl ? "You are controlling" : session.status)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if session.isLoading { ProgressView().controlSize(.mini) }
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            session.expanded.toggle()
                            if session.expanded { session.userControl = true }
                        }
                    } label: { Image(systemName: session.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel(session.expanded ? "Minimize browser" : "Take control of browser")
                    Button { session.close() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Close browser")
                }
                .padding(10)
                if session.expanded {
                    HStack(spacing: 12) {
                        Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                        Text(session.currentURL).font(.caption2).lineLimit(1)
                            .textSelection(.enabled)
                        Spacer()
                        Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                BrowserSurface(session: session)
                    .frame(height: session.expanded ? 390 : 126)
                    .allowsHitTesting(session.expanded)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if !session.expanded {
                            Text("Tap expand to take control")
                                .font(.caption2).padding(5)
                                .background(.regularMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
            }
            .frame(width: session.expanded ? 350 : 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.cyan.opacity(0.25)))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .onAppear { withAnimation { appear = true } }
        }
    }
}
