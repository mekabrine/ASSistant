import Foundation
import UIKit

enum HTMLAppError: LocalizedError {
    case missingSkill
    case invalidHTML
    case tooLarge
    case missingPublishingToken
    case badHostingResponse
    case invalidSourceURL
    case installNotAvailable

    var errorDescription: String? {
        switch self {
        case .missingSkill: return "HTMLApp skill resource is missing from the app bundle."
        case .invalidHTML: return "The model did not return a complete standalone HTML document."
        case .tooLarge: return "Generated HTML exceeds the 900 KB publish limit."
        case .missingPublishingToken: return "Set your GitHub personal access token in Settings → Publishing."
        case .badHostingResponse: return "Publishing did not return a public HTTPS source URL."
        case .invalidSourceURL: return "The hosted file URL is not valid for HTMLApp import."
        case .installNotAvailable: return "HTMLApp is not installed or did not accept the import link."
        }
    }
}

enum HTMLAppBuilder {
    static let maxHTMLBytes = 900_000

    static func skill() throws -> String {
        guard let url = Bundle.main.url(forResource: "HTMLApp-AI-App-Builder-SKILL", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { throw HTMLAppError.missingSkill }
        return content
    }

    static func normalizedHTML(_ input: String) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.range(of: "```html", options: .caseInsensitive) {
            text = String(text[start.upperBound...])
            if let end = text.range(of: "```") { text = String(text[..<end.lowerBound]) }
        } else if let start = text.range(of: "```") {
            text = String(text[start.upperBound...])
            if let end = text.range(of: "```") { text = String(text[..<end.lowerBound]) }
        }
        if let first = text.range(of: "<!doctype html", options: .caseInsensitive) {
            text = String(text[first.lowerBound...])
        } else if let first = text.range(of: "<html", options: .caseInsensitive) {
            text = String(text[first.lowerBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.localizedCaseInsensitiveContains("<html"),
              text.localizedCaseInsensitiveContains("</html>"),
              text.localizedCaseInsensitiveContains("<body"),
              text.localizedCaseInsensitiveContains("</body>"),
              text.localizedCaseInsensitiveContains("<script"),
              text.localizedCaseInsensitiveContains("</script>") else { throw HTMLAppError.invalidHTML }
        guard text.utf8.count < maxHTMLBytes else { throw HTMLAppError.tooLarge }
        return text
    }

    static func generate(
        request: String,
        profile: ProviderProfile,
        existing: GeneratedApp? = nil,
        onDelta: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> GeneratedApp {
        let instructions = try skill()
        let prior = existing.map {
            "\nExisting app (preserve storage keys and data, edit conservatively):\n" + String($0.html.prefix(120_000))
        } ?? ""
        let prompt = """
        \(instructions)
        \nUser request:
        \(request)
        \nAdditional ASSistant output contract:
        Respond with ONLY the complete HTML file, starting with <!doctype html>.
        No markdown fences. Include all CSS and JS inline. No secrets or fabricated endpoints.
        Use stable data-forge-screen identifiers. Make usable controls, local persistence,
        visible error states and a helpful empty state. Target iOS 16 HTMLApp WKWebView.
        No external CDN dependencies. Avoid unsupported native bridge method names.
        \(prior)
        """
        let messages = [LLMMessage(role: "system", content: "You are the HTMLApp app builder. Produce complete functional single-file HTML."),
                        LLMMessage(role: "user", content: prompt)]
        var buildProfile = profile
        buildProfile.maxOutputTokens = max(6144, profile.maxOutputTokens)
        let output = try await LLMService.request(profile: buildProfile, messages: messages, onDelta: onDelta)
        let html = try normalizedHTML(output)
        var app = existing ?? GeneratedApp(title: title(from: html) ?? "Custom App", prompt: request, html: html)
        app.prompt = request
        app.html = html
        app.title = title(from: html) ?? app.title
        app.version = existing.map { $0.version + 1 } ?? 1
        app.updatedAt = .now
        // A newly edited version is not yet hosted.
        app.sourceURL = nil
        return app
    }

    static func title(from html: String) -> String? {
        guard let range = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let raw = String(html[range])
        let stripped = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : String(stripped.prefix(80))
    }

    static func fileName(_ title: String) -> String {
        let valid = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return String(valid.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + ".html"
    }

    static func installURL(for rawURL: String) throws -> URL {
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
              let host = url.host, host.contains("."), url.user == nil, url.password == nil,
              host.lowercased() != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal") else { throw HTMLAppError.invalidSourceURL }
        var components = URLComponents()
        components.scheme = "htmlapp"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let deepLink = components.url else { throw HTMLAppError.invalidSourceURL }
        return deepLink
    }

    @MainActor
    static func openHTMLApp(_ sourceURL: String) async throws {
        let link = try installURL(for: sourceURL)
        let opened = await UIApplication.shared.open(link)
        guard opened else { throw HTMLAppError.installNotAvailable }
        // Opening does NOT prove the user confirmed installation inside HTMLApp.
    }
}

enum HTMLPublisher {
    static func uploadToGist(_ app: GeneratedApp) async throws -> String {
        guard let token = KeychainStore.get("github.publisher"), !token.isEmpty else {
            throw HTMLAppError.missingPublishingToken
        }
        guard app.html.utf8.count < HTMLAppBuilder.maxHTMLBytes else { throw HTMLAppError.tooLarge }
        var request = URLRequest(url: URL(string: "https://api.github.com/gists")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ASSistant-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let filename = HTMLAppBuilder.fileName(app.title)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "description": "HTMLApp generated by ASSistant - \(app.title)",
            "public": false, // Unlisted, NOT private: anyone with URL can read source.
            "files": [filename: ["content": app.html]]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AIRequestError.http(code, String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [String: [String: Any]],
              let raw = files[filename]?["raw_url"] as? String else { throw HTMLAppError.badHostingResponse }
        _ = try HTMLAppBuilder.installURL(for: raw)
        return raw
    }

    // Alternative for users with a server: POST text/html and accept {"url":"https://..."}.
    static func uploadToCustomEndpoint(_ app: GeneratedApp, endpoint: String, bearer: String?) async throws -> String {
        guard let url = URL(string: endpoint), url.scheme == "https",
              url.host != nil else { throw HTMLAppError.invalidSourceURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("text/html; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = app.html.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["url"] as? String else { throw HTMLAppError.badHostingResponse }
        _ = try HTMLAppBuilder.installURL(for: raw)
        return raw
    }
}
