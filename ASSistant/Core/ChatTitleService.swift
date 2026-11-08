import Foundation

@MainActor
enum ChatTitleService {
    static func fallback(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let stripped = firstLine.replacingOccurrences(of: "[#*<>{}]", with: "",
                                                      options: .regularExpression)
        return String(stripped.split(separator: " ").prefix(7).joined(separator: " ").prefix(62))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func generate(chat: ChatThread, messages: [ChatMessage],
                         availableProviders: [ProviderProfile],
                         fallbackProvider: ProviderProfile) async -> String? {
        let chosenID = UserDefaults.standard.string(forKey: "chatTitleProviderID") ?? ""
        var provider = availableProviders.first(where: { $0.id.uuidString == chosenID }) ?? fallbackProvider
        let override = (UserDefaults.standard.string(forKey: "chatTitleModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { provider.model = override }
        provider.temperature = 0.2
        provider.maxOutputTokens = 60
        let excerpt = messages.suffix(50)
            .filter { $0.status != "superseded" }
            .map { "[\($0.role)] \(String($0.content.prefix(350)))" }
            .joined(separator: "\n")
        guard !excerpt.isEmpty else { return nil }
        let prompt = """
        Create a concise, informative chat title of 3–7 words based only on these
        messages. Use plain text only. Do not use quotes, Markdown, punctuation
        at the end, private secrets, or a generic title like New Chat.
        Return only the title.
        Messages:
        \(String(excerpt.prefix(12000)))
        """
        do {
            let result = try await LLMService.request(
                profile: provider, messages: [LLMMessage(role: "user", content: prompt)]
            ) { _ in }
            let title = result.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'*# "))
            guard (3...75).contains(title.count),
                  !title.contains("<assistant_tool>"),
                  !MemoryEngine.looksSensitive(title) else { return nil }
            return title
        } catch {
            return nil
        }
    }

    static func shouldRename(count: Int) -> Bool {
        count == 1 || count == 2 || (count > 0 && count % 5 == 0)
    }
}
