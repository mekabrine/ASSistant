import Foundation
import WebKit
import SwiftUI

struct BrowserElement: Identifiable, Equatable {
    var id: String
    var text: String
    var href: String
    var kind: String
    var inputType: String = ""
    var placeholder: String = ""
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

private final class WeakBrowserScriptHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

/// One shared, real WKWebView for human and agent use.
/// Unlike the uploaded desktop Python/Playwright script, this runs on iOS 16.
/// It exposes bounded page text and clickable links, not unrestricted JS execution.
@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    let web: WKWebView
    @Published var requiresHuman = false
    @Published var handoffReason = ""
    @Published var activeAgent = false
    @Published var visible = false
    @Published var expanded = false
    @Published var userControl = false
    @Published var isLoading = false
    @Published var currentURL = ""
    @Published var title = "Browser"
    @Published var pageText = ""
    @Published var links: [BrowserElement] = []
    @Published var controls: [BrowserElement] = []
    @Published var status = "Ready"
    @Published var lastError = ""
    @Published var progress: Double = 0
    @Published var thumbnail: UIImage?
    @Published var selectedVariants: [String: String] = [:]
    @Published var addedToCart = false
    @Published var orderSubmissionRequested = false
    @Published var lastProductURL = ""
    @Published var lastProductTitle = ""
    @Published var lastProductDescription = ""
    @Published var orderSubmissionAttempted = false
    var variationSelectionInProgress = false

    var isAmazonProductPage: Bool {
        guard ShoppingPolicy.amazonHost(web.url) else { return false }
        let path = web.url?.path.lowercased() ?? ""
        return path.contains("/dp/") || path.contains("/gp/product/") ||
            path.contains("/gp/aw/d/")
    }

    var onPageUpdated: (() -> Void)?
    var pendingRestoredScrollY: CGFloat?

    private var pending: CheckedContinuation<Void, Error>?
    private var navigationSequence = 0
    private var thumbnailTask: Task<Void, Never>?

    init(tabID: UUID = UUID()) {
        self.id = tabID
        let config = WKWebViewConfiguration()
        // Shared persistent WebKit login state across browsers/chats, isolated
        // from Safari and from the user's separate Google/Spotify OAuth tokens.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 640), configuration: config)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.configuration.userContentController.add(WeakBrowserScriptHandler(delegate: self), name: "assistantUserInteraction")
        web.configuration.userContentController.addUserScript(WKUserScript(source: """
        document.addEventListener('click',function(e){
          if(window.__assistantAutomation)return;
          const interactive=e.target.closest('a,button,input,textarea,select,[role="button"],[contenteditable="true"]');
          if(interactive)window.webkit.messageHandlers.assistantUserInteraction.postMessage('tap');
        },true);
        document.addEventListener('input',function(e){
          if(!window.__assistantAutomation)
            window.webkit.messageHandlers.assistantUserInteraction.postMessage('typing');
        },true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.allowsBackForwardNavigationGestures = true
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "assistantUserInteraction" else { return }
        userControl = true
        if !requiresHuman { handoffReason = "You are interacting with this page." }
        status = "You are in control"
    }

    func requestHuman(_ reason: String) {
        handoffReason = String(reason.prefix(220))
        requiresHuman = true
        userControl = true
        visible = true
        expanded = true
        status = "Action needed"
    }

    func returnControl() {
        userControl = false
        requiresHuman = false
        handoffReason = ""
        status = "AI can continue"
    }

    nonisolated static func safeURL(_ raw: String) -> URL? {
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

    static func looksLikeChallenge(_ content: String) -> Bool {
        let lowered = content.lowercased()
        return [
            "unusual traffic", "verify you are human", "verify that you are human",
            "before you continue to google", "our systems have detected unusual",
            "complete the captcha", "captcha challenge", "please verify you are a human",
            "security check", "press and hold to confirm you are a human"
        ].contains(where: lowered.contains)
    }

    func search(_ query: String, site: String? = nil) async throws -> String {
        let trimmed = String(query.prefix(220)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserFailure.badURL }
        let amazon = ["amazon", "amazon.com"].contains((site ?? "").lowercased())
        let terms = (amazon ? "site:amazon.com " : "") + trimmed
        var engines: [(base: String, term: String, key: String)] = []
        if amazon {
            // Start on Amazon itself, so shopping tasks can follow product
            // links and select variations without hopping through Google.
            engines.append(("https://www.amazon.com/s", trimmed, "k"))
        }
        engines += [
            ("https://www.google.com/search", terms, "q"),
            ("https://www.bing.com/search", terms, "q"),
            ("https://duckduckgo.com/", terms, "q")
        ]
        var lastFailure = "Search pages were unavailable."
        for engine in engines {
            try Task.checkCancellation()
            var components = URLComponents(string: engine.base)!
            components.queryItems = [URLQueryItem(name: engine.key, value: engine.term)]
            guard let url = components.url else { continue }
            do {
                let observation = try await navigate(url.absoluteString)
                if Self.looksLikeChallenge(observation) || Self.needsHuman(observation) {
                    lastFailure = "The search provider requested human verification."
                    continue
                }
                return observation
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastFailure = error.localizedDescription
                continue
            }
        }
        requestHuman("Search providers were blocked: " + lastFailure +
                     " Complete any security challenge, then return control to ASSistant.")
        return "Human help required with live browser. " + lastFailure
    }

    /// User-triggered address/search navigation. Never changes the handoff
    /// flag or reads the resulting page into the model until the user
    /// explicitly returns control.
    func navigateAsUser(_ input: String) throws {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { throw BrowserFailure.badURL }
        let url: URL?
        if typed.hasPrefix("https://") {
            url = Self.safeURL(typed)
        } else if typed.contains(".") && !typed.contains(" ") {
            url = Self.safeURL("https://" + typed)
        } else {
            var search = URLComponents(string: "https://www.google.com/search")!
            search.queryItems = [URLQueryItem(name: "q", value: String(typed.prefix(220)))]
            url = search.url
        }
        guard let target = url, Self.safeURL(target.absoluteString) != nil else {
            throw BrowserFailure.badURL
        }
        userControl = true
        status = "You are navigating"
        guard web.load(URLRequest(url: target)) != nil else { throw BrowserFailure.unavailable }
    }

    func navigate(_ raw: String) async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        guard let url = Self.safeURL(raw) else { throw BrowserFailure.badURL }
        guard pending == nil else { throw BrowserFailure.busy }
        visible = true
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
        guard !userControl else { throw BrowserFailure.userTookControl }
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
            const id=e.dataset.assistantLink||'L'+(window.__assistantLinkCounter=(window.__assistantLinkCounter||0)+1);
            e.dataset.assistantLink=id;
            return {id:id,kind:'link',
              text:(e.innerText||e.getAttribute('aria-label')||e.title||'').trim().slice(0,140),
              href:e.href||''};
          }).filter(e=>e.href.startsWith('https://'));
          const controls=[...document.querySelectorAll('input,button,textarea,[role="button"]')]
            .filter(e => {const r=e.getBoundingClientRect();return r.width>0&&r.height>0})
            .slice(0,50).map((e,i)=>{
              const id=e.dataset.assistantControl||'E'+(window.__assistantControlCounter=(window.__assistantControlCounter||0)+1);
              e.dataset.assistantControl=id;
              return {id:id,kind:e.tagName.toLowerCase(),
                text:(e.innerText||e.getAttribute('aria-label')||(e.type==='submit'?e.value:'')||e.name||'').trim().slice(0,100),
                href:'',inputType:(e.type||'').toLowerCase(),
                placeholder:e.placeholder||''};
            });
          const roots=[document.querySelector('main'),document.querySelector('article'),document.body].filter(Boolean);
          const text=roots.map(e=>e.innerText||'').sort((a,b)=>b.length-a.length)[0]||'';
          const productSummary=document.querySelector('#feature-bullets')?.innerText ||
            document.querySelector('#productDescription')?.innerText || '';
          return {url:location.href,title:document.title||'',text:text.slice(0,20000),
            productSummary:productSummary.slice(0,460),links:links,controls:controls};
        })()
        """#
        do {
            let value = try await web.evaluateJavaScript(js)
            guard let state = value as? [String: Any] else { throw BrowserFailure.unavailable }
            currentURL = (state["url"] as? String) ?? web.url?.absoluteString ?? ""
            title = (state["title"] as? String) ?? "Website"
            pageText = (state["text"] as? String) ?? ""
            if isAmazonProductPage,
               let safe = Self.safeURL(currentURL) {
                let previousPath = Self.safeURL(lastProductURL)?.path
                if !variationSelectionInProgress, let previousPath,
                   previousPath != safe.path {
                    selectedVariants = [:]
                    addedToCart = false
                    orderSubmissionRequested = false
                    orderSubmissionAttempted = false
                }
                lastProductURL = safe.absoluteString
                lastProductTitle = title
                lastProductDescription = (state["productSummary"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            links = ((state["links"] as? [[String: String]]) ?? []).map {
                BrowserElement(id: $0["id"] ?? "", text: $0["text"] ?? "",
                               href: $0["href"] ?? "", kind: "link")
            }
            controls = ((state["controls"] as? [[String: String]]) ?? []).map {
                BrowserElement(id: $0["id"] ?? "", text: $0["text"] ?? "",
                               href: "", kind: $0["kind"] ?? "",
                               inputType: $0["inputType"] ?? "",
                               placeholder: $0["placeholder"] ?? "")
            }
            status = "Page ready"
            captureThumbnail()
            onPageUpdated?()
            let lowerText = pageText.lowercased()
            let needsPassword = controls.contains(where: { $0.inputType == "password" })
            let needsCode = controls.contains(where: { $0.kind == "input" }) &&
                ["verification code", "security code", "two-factor authentication",
                 "authenticator code", "one-time passcode"].contains(where: lowerText.contains)
            let host = web.url?.host?.lowercased() ?? ""
            let searchProvider = ["www.google.com", "www.bing.com", "duckduckgo.com",
                                  "www.duckduckgo.com"].contains(host)
                || (ShoppingPolicy.amazonHost(web.url) && web.url?.path == "/s")
            if Self.looksLikeChallenge(pageText) && !searchProvider {
                requestHuman("Complete this website's CAPTCHA or security verification in the browser.")
            } else if needsPassword && !searchProvider {
                requestHuman("Sign into this website yourself. Passwords stay inside the website.")
            } else if needsCode {
                requestHuman("Enter your security or verification code yourself. The code is never sent to the AI.")
            }
            var result = "PAGE: " + title + "\nURL: " + currentURL + "\n\n"
            result += String(pageText.prefix(11500)) + "\n\nLINKS:\n"
            result += links.prefix(55).map { "\($0.id) \($0.text): \($0.href)" }.joined(separator: "\n")
            result += "\nSEARCH/FORM CONTROLS (no input values):\n"
            result += controls.prefix(30).map {
                "\($0.id) \($0.kind) \($0.inputType) \($0.text) \($0.placeholder)"
            }.joined(separator: "\n")
            if Self.needsHuman(result) {
                // Search providers (including Amazon results) may fall back
                // before asking the human to solve CAPTCHA.
                if searchProvider {
                    return String(result.prefix(17500))
                }
                requestHuman("Complete the site sign-in, CAPTCHA, or security challenge, then tap Return control to AI.")
                return "Protected page requires human action. Do not read credentials or security codes."
            }
            return String(result.prefix(17500))
        } catch {
            lastError = error.localizedDescription
            throw BrowserFailure.unavailable
        }
    }


    /// Agent may fill ONLY search/query fields, never passwords, emails, or
    /// arbitrary account forms. No form submission occurs from this command.
    func fillSearch(id: String, text: String) async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        guard let field = controls.first(where: { $0.id == id }),
              field.kind == "input",
              ["search", "text"].contains(field.inputType),
              [field.placeholder, field.text].joined(separator: " ")
                .range(of: "search|find|query", options: .regularExpression.union(.caseInsensitive)) != nil,
              text.count <= 240 else { throw BrowserFailure.invalidLink }
        let js = #"""
        args => {
          const el=document.querySelector('[data-assistant-control="'+args.id+'"]');
          if(!el || (el.type!=='search'&&el.type!=='text')) return false;
          window.__assistantAutomation=true;
          try {
            el.focus();el.value=args.value;
            el.dispatchEvent(new Event('input',{bubbles:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
          } finally { window.__assistantAutomation=false; }
          return true;
        }
        """#
        let value = try await web.evaluateJavaScript("(" + js + ")(" +
            String(data: try JSONSerialization.data(withJSONObject: [
                "id": id, "value": text
            ]), encoding: .utf8)! + ")")
        guard (value as? Bool) == true else { throw BrowserFailure.invalidLink }
        return "Filled a public page's search field. A search button or return key may still be needed.\n" +
            (try await read())
    }

    /// A narrowly scoped submit for website search forms only. Navigation to
    /// cart/checkout/account/payment operations is never automatically submitted.
    func submitSearch(id: String) async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        guard let field = controls.first(where: { $0.id == id }),
              field.kind == "button" || field.kind == "input",
              let host = web.url?.host?.lowercased(),
              ["google.com", "www.google.com", "amazon.com", "www.amazon.com", "bing.com", "www.bing.com"]
                .contains(host) else { throw BrowserFailure.invalidLink }
        let label = [field.placeholder, field.text].joined(separator: " ").lowercased()
        let safeLabel = label.contains("search") || label.contains("find") ||
            (host.contains("amazon") && label.trimmingCharacters(in: .whitespaces) == "go")
        guard safeLabel else { throw BrowserFailure.invalidLink }
        let js = #"""
        id => {
          const element=document.querySelector('[data-assistant-control="'+id+'"]');
          if(!element) return false;
          const form=element.closest('form');
          const action=(form?.action||'').toLowerCase();
          if(!form || !(action.includes('/search') || action.includes('/s?')
              || action.includes('/s') || action.includes('google.com'))) return false;
          window.__assistantAutomation=true;
          try { element.click(); } finally { window.__assistantAutomation=false; }
          return true;
        }
        """#
        let encodedID = String(decoding: try JSONEncoder().encode(id), as: UTF8.self)
        let value = try await web.evaluateJavaScript("(" + js + ")(" + encodedID + ")")
        guard (value as? Bool) == true else { throw BrowserFailure.invalidLink }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return try await read()
    }

    func scrollDown() async throws -> String {
        guard !userControl else { throw BrowserFailure.userTookControl }
        _ = try await web.evaluateJavaScript("window.scrollBy(0, Math.min(900, window.innerHeight))")
        try? await Task.sleep(nanoseconds: 550_000_000)
        let result = try await read()
        captureThumbnail()
        return result
    }

    func close() {
        stop()
        visible = false
        expanded = false
        returnControl()
        // WKUserContentController retains message handlers; remove to avoid
        // retaining a discarded web view and its authenticated page in memory.
        web.configuration.userContentController.removeScriptMessageHandler(forName: "assistantUserInteraction")
    }

    static func needsHuman(_ observation: String) -> Bool {
        let lower = observation.lowercased()
        return ["verify you are human", "verify that you are human",
                "complete the captcha", "solve the captcha",
                "enter the security code", "two-factor authentication",
                "enter the verification code", "confirm your identity",
                "sign in to continue", "log in to continue",
                "unusual traffic from your computer network"].contains(where: lower.contains)
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

    func captureThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self, !Task.isCancelled,
                  self.web.bounds.width > 1, self.web.bounds.height > 1 else { return }
            let config = WKSnapshotConfiguration()
            config.rect = self.web.bounds
            config.afterScreenUpdates = false
            self.web.takeSnapshot(with: config) { [weak self] image, _ in
                Task { @MainActor in
                    guard let self, let image else { return }
                    self.thumbnail = image
                }
            }
        }
    }

    func goBack() {
        if web.canGoBack { web.goBack() }
    }

    func goForward() {
        if web.canGoForward { web.goForward() }
    }

    func reload() { web.reload() }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        progress = 0.15
        status = "Loading website…"
        currentURL = webView.url?.absoluteString ?? currentURL
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureThumbnail()
        isLoading = false
        progress = 1
        currentURL = webView.url?.absoluteString ?? currentURL
        title = webView.title ?? title
        onPageUpdated?()
        if let scrollY = pendingRestoredScrollY {
            pendingRestoredScrollY = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard let self else { return }
                self.web.scrollView.setContentOffset(
                    CGPoint(x: 0, y: max(0, scrollY)), animated: false
                )
            }
        }
        if let waiter = pending {
            pending = nil
            waiter.resume()
        }
        if !userControl {
            Task { @MainActor [weak self] in _ = try? await self?.read() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Some shopping links use target=_blank. Reuse the user's visible
        // browser window instead of silently failing or opening Safari.
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           Self.safeURL(url.absoluteString) != nil {
            web.load(URLRequest(url: url))
        }
        return nil
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
        // The injected click/input handler distinguishes genuine human page
        // interactions from the agent's narrowly scoped programmatic clicks.
        // Treating *every* linkActivated navigation as human takeover caused
        // automated product-variation clicks to halt the agent one step early.
        decisionHandler(Self.safeURL(url.absoluteString) != nil ? .allow : .cancel)
    }
}

struct BrowserSurface: UIViewRepresentable {
    @ObservedObject var session: BrowserSession
    func makeUIView(context: Context) -> WKWebView { session.web }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

