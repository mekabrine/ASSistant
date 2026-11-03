import Foundation

enum AIRequestError: LocalizedError {
    case noModel
    case invalidURL
    case unsupportedResponse
    case http(Int, String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .noModel: return "Choose a model ID in Settings → Providers."
        case .invalidURL: return "Invalid provider URL. Use an HTTPS endpoint or an explicitly configured local-network endpoint."
        case .unsupportedResponse: return "The provider returned a response ASSistant could not parse."
        case .http(let status, let detail): return "Provider HTTP \(status): \(detail)"
        case .missingKey: return "This provider needs an API key on this device."
        }
    }
}

enum LLMService {
    static func request(
        profile: ProviderProfile,
        messages: [LLMMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIRequestError.noModel
        }
        let adapter = profile.adapter.lowercased()
        if adapter == "anthropic" {
            return try await anthropic(profile: profile, messages: messages, onDelta: onDelta)
        } else if adapter == "gemini" {
            return try await gemini(profile: profile, messages: messages, onDelta: onDelta)
        }
        return try await openAI(profile: profile, messages: messages, onDelta: onDelta)
    }

    static func key(for profile: ProviderProfile) -> String? {
        KeychainStore.get("provider.\(profile.id.uuidString)")
    }

    static func baseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw AIRequestError.invalidURL }
        if scheme == "http" {
            // ATS generally denies remote HTTP. Allow only loopback, explicitly, for local model servers.
            guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw AIRequestError.invalidURL }
        }
        return url
    }

    private static func endpoint(profile: ProviderProfile, ending: String) throws -> URL {
        let root = try baseURL(profile.baseURL)
        let path = root.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(ending.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            return root
        }
        return root.appendingPathComponent(ending)
    }

    private static func authorizedRequest(_ url: URL, profile: ProviderProfile, method: String = "POST") throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = (key(for: profile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.authMode != "none" {
            guard !key.isEmpty else { throw AIRequestError.missingKey }
            if profile.authMode == "header" {
                let header = profile.apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
                guard header.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
                      !["host", "content-length"].contains(header.lowercased()) else {
                    throw AIRequestError.invalidURL
                }
                request.setValue(key, forHTTPHeaderField: header)
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    private static func openAI(
        profile: ProviderProfile, messages: [LLMMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try endpoint(profile: profile, ending: "chat/completions")
        var request = try authorizedRequest(url, profile: profile)
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": profile.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "max_tokens": max(16, min(profile.maxOutputTokens, 16384)),
            "temperature": profile.temperature
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIRequestError.unsupportedResponse }
        guard (200...299).contains(http.statusCode) else {
            var details = ""
            for try await line in bytes.lines {
                details += line
                if details.count > 700 { break }
            }
            throw AIRequestError.http(http.statusCode, String(details.prefix(700)))
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        var accumulated = ""
        if contentType.contains("text/event-stream") {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if chunk == "[DONE]" { break }
                guard let data = chunk.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let first = choices.first else { continue }
                let delta = first["delta"] as? [String: Any]
                let next = delta?["content"] as? String ?? ""
                if !next.isEmpty {
                    accumulated += next
                    await onDelta(next)
                }
            }
        } else {
            var raw = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                raw += line
                guard raw.utf8.count < 5_000_000 else { throw AIRequestError.unsupportedResponse }
            }
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let next = message["content"] as? String else { throw AIRequestError.unsupportedResponse }
            accumulated = next
            await onDelta(next)
        }
        guard !accumulated.isEmpty else { throw AIRequestError.unsupportedResponse }
        return accumulated
    }

    private static func anthropic(
        profile: ProviderProfile, messages: [LLMMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = try endpoint(profile: profile, ending: "messages")
        var request = try authorizedRequest(url, profile: profile)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Anthropic takes system instructions outside the messages array.
        let systemText = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let turns = messages.filter { $0.role != "system" }.map {
            ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": profile.model, "system": systemText, "messages": turns,
            "max_tokens": max(32, profile.maxOutputTokens)
        ])
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else { throw AIRequestError.unsupportedResponse }
        let value = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !value.isEmpty else { throw AIRequestError.unsupportedResponse }
        await onDelta(value)
        return value
    }

    private static func gemini(
        profile: ProviderProfile, messages: [LLMMessage],
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let root = try baseURL(profile.baseURL)
        let url = root.appendingPathComponent("models")
            .appendingPathComponent(profile.model + ":generateContent")
        var request = try authorizedRequest(url, profile: profile)
        let key = key(for: profile) ?? ""
        if profile.authMode != "none" {
            guard !key.isEmpty else { throw AIRequestError.missingKey }
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        let turns = messages.filter { $0.role != "system" }.map { m -> [String: Any] in
            ["role": m.role == "assistant" ? "model" : "user", "parts": [["text": m.content]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": turns,
            "generationConfig": ["maxOutputTokens": profile.maxOutputTokens, "temperature": profile.temperature]
        ])
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw AIRequestError.unsupportedResponse }
        let value = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !value.isEmpty else { throw AIRequestError.unsupportedResponse }
        await onDelta(value)
        return value
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIRequestError.unsupportedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw AIRequestError.http(http.statusCode, String(decoding: data.prefix(700), as: UTF8.self))
        }
        return data
    }

    static func discoverModels(profile: ProviderProfile) async throws -> [String] {
        let root = try baseURL(profile.baseURL)
        let url: URL
        let lowerPath = root.path.lowercased()
        if lowerPath.hasSuffix("/chat/completions") {
            url = root.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("models")
        } else if lowerPath.hasSuffix("/messages") {
            url = root.deletingLastPathComponent().appendingPathComponent("models")
        } else {
            url = root.appendingPathComponent("models")
        }
        var request = try authorizedRequest(url, profile: profile, method: "GET")
        if profile.adapter == "anthropic" {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if profile.adapter == "gemini", let key = key(for: profile) {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        let data = try await send(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIRequestError.unsupportedResponse
        }
        let rows = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        return Array(Set(rows.compactMap { row in
            (row["id"] as? String ?? row["name"] as? String)?
                .replacingOccurrences(of: "models/", with: "")
        })).sorted()
    }
}
