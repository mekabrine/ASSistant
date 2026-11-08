import Foundation

struct GmailSummary: Identifiable {
    var id: String
    var threadID: String
    var from: String
    var to: String
    var subject: String
    var date: String
    var snippet: String
    var body: String

    var compactText: String {
        "ID: \(id)\nFrom: \(from)\nTo: \(to)\nSubject: \(subject)\nDate: \(date)\nSnippet: \(snippet)\n" +
            (body.isEmpty ? "" : "Body:\n\(String(body.prefix(1200)))")
    }
}

enum GmailService {
    static func list(query: String, limit: Int = 6) async throws -> String {
        let capped = min(max(limit, 1), 10)
        let clean = String(query.prefix(250))
        let (data, _) = try await ConnectedServices.shared.fetch(
            .google, path: "/gmail/v1/users/me/messages",
            query: [
                URLQueryItem(name: "q", value: clean),
                URLQueryItem(name: "maxResults", value: String(capped))
            ]
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let refs = (json?["messages"] as? [[String: String]]) ?? []
        guard !refs.isEmpty else { return "No Gmail messages matched the query." }
        var output: [String] = []
        for reference in refs.prefix(capped) {
            try Task.checkCancellation()
            guard let id = reference["id"] else { continue }
            do {
                let result = try await message(id: id)
                output.append(result.compactText)
            } catch {
                output.append("Gmail message \(id) could not be read: \(error.localizedDescription)")
            }
        }
        return String(("Gmail results for \(clean.isEmpty ? "recent mail" : clean):\n\n" +
                       output.joined(separator: "\n\n---\n\n")).prefix(13000))
    }

    static func message(id: String) async throws -> GmailSummary {
        guard id.range(of: "^[A-Za-z0-9_-]{6,100}$", options: .regularExpression) != nil else {
            throw ConnectedServicesError.invalidInput("Gmail message ID")
        }
        let (data, _) = try await ConnectedServices.shared.fetch(
            .google, path: "/gmail/v1/users/me/messages/" + id,
            query: [URLQueryItem(name: "format", value: "full")]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectedServicesError.invalidServerResponse
        }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: String]] ?? []
        func header(_ key: String) -> String {
            headers.first(where: { $0["name"]?.lowercased() == key.lowercased() })?["value"] ?? ""
        }
        let snippet = json["snippet"] as? String ?? ""
        var bodies: [String] = []
        func collect(_ node: [String: Any], depth: Int) {
            guard depth < 5, bodies.joined().count < 5000 else { return }
            let mime = (node["mimeType"] as? String ?? "").lowercased()
            if mime == "text/plain", let body = node["body"] as? [String: Any],
               let encoded = body["data"] as? String,
               let decoded = decodeBase64URL(encoded), let text = String(data: decoded, encoding: .utf8) {
                bodies.append(String(text.prefix(5000)))
            }
            for part in (node["parts"] as? [[String: Any]] ?? []).prefix(30) {
                collect(part, depth: depth + 1)
            }
        }
        collect(payload, depth: 0)
        return GmailSummary(
            id: json["id"] as? String ?? id,
            threadID: json["threadId"] as? String ?? "",
            from: header("From"), to: header("To"),
            subject: header("Subject"), date: header("Date"),
            snippet: String(snippet.prefix(750)),
            body: String(bodies.joined(separator: "\n").prefix(5000))
        )
    }

    static func send(to recipient: String, subject: String, body: String) async throws -> String {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#,
                       options: .regularExpression) != nil,
              to.count <= 254,
              !subject.contains("\r"), !subject.contains("\n"),
              !recipient.contains("\r"), !recipient.contains("\n"),
              subject.utf8.count <= 500,
              body.utf8.count <= 120_000 else {
            throw ConnectedServicesError.invalidInput("recipient, subject or message size")
        }
        // Subject is encoded as an RFC 2047 UTF-8 encoded-word to avoid
        // accidentally interpreting non-ASCII text as a MIME header.
        let encodedSubject = "=?UTF-8?B?" + Data(subject.utf8).base64EncodedString() + "?="
        let raw = [
            "MIME-Version: 1.0",
            "To: \(to)",
            "Subject: \(encodedSubject)",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data(body.utf8).base64EncodedString()
        ].joined(separator: "\r\n")
        let data = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let (response, _) = try await ConnectedServices.shared.fetch(
            .google, path: "/gmail/v1/users/me/messages/send", method: "POST",
            json: ["raw": data]
        )
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = result["id"] as? String else {
            throw ConnectedServicesError.invalidServerResponse
        }
        return "Gmail accepted the message addressed to \(to), subject “\(subject)”. Message ID: \(id). Delivery is not guaranteed."
    }

    private static func decodeBase64URL(_ encoded: String) -> Data? {
        let normalized = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized + padding)
    }
}
