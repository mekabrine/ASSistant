import Foundation

/// Two-stage memory retrieval: compact directory first, full text by UUID.
/// Never expose sensitive items or those scoped to another chat/agent.
enum MemoryDirectory {
    static func allowed(_ memory: MemoryItem, chat: ChatThread, agent: AgentProfile) -> Bool {
        guard !memory.isSensitive, memory.expiresAt.map({ $0 > Date() }) ?? true else { return false }
        return memory.scope == "global"
            || memory.scope == "chat:\(chat.id.uuidString)"
            || memory.scope == "agent:\(agent.id.uuidString)"
    }

    static func list(_ memories: [MemoryItem], chat: ChatThread, agent: AgentProfile,
                     category: String? = nil, days: Int? = nil, limit: Int = 100) -> String {
        let filtered = memories.filter { memory in
            guard allowed(memory, chat: chat, agent: agent) else { return false }
            if let category, !category.isEmpty && category.lowercased() != "all",
               (memory.category ?? memory.kind).localizedCaseInsensitiveCompare(category) != .orderedSame {
                return false
            }
            if let days, (1...3650).contains(days),
               memory.updatedAt < Date().addingTimeInterval(-Double(days) * 86400) { return false }
            return true
        }.sorted { $0.updatedAt > $1.updatedAt }
        guard !filtered.isEmpty else { return "No memories matched that category or timeframe." }
        let titles = filtered.prefix(min(max(1, limit), 120)).map { item in
            let title = (item.title?.isEmpty == false ? item.title! : MemoryEngine.shortTitle(item.text))
            return "[\(item.id.uuidString)] \(item.category ?? item.kind): \(title) — \(item.updatedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        let categories = Dictionary(grouping: filtered, by: { $0.category ?? $0.kind })
            .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        return "MEMORY DIRECTORY (\(filtered.count) items): \(categories)\n" +
            titles.joined(separator: "\n") +
            (filtered.count > titles.count ? "\nMore memories exist; filter by category or days." : "")
    }

    static func get(_ id: String, memories: [MemoryItem], chat: ChatThread, agent: AgentProfile) -> String {
        guard let uuid = UUID(uuidString: id),
              let item = memories.first(where: { $0.id == uuid && allowed($0, chat: chat, agent: agent) })
        else { return "No accessible memory exists with that ID." }
        return """
        Memory \(item.id.uuidString)
        Category: \(item.category ?? item.kind)
        Title: \(item.title ?? MemoryEngine.shortTitle(item.text))
        Last updated: \(item.updatedAt)
        Scope: \(item.scope)
        Full contents:
        \(String(item.text.prefix(10000)))
        """
    }

    static let instructions = """
    You can search saved memories without loading their entire contents into
    the model context. Use a concise index first, then request a specific ID:
    <assistant_tool>{"name":"memory_list","category":"Preferences","days":30}</assistant_tool>
    <assistant_tool>{"name":"memory_list","category":"all"}</assistant_tool>
    <assistant_tool>{"name":"memory_get","memoryID":"UUID_FROM_INDEX"}</assistant_tool>
    You may filter by category and last N days (1...3650). Memory listings
    return category, short title, ID and updated date; memory_get returns the
    full permitted content. No secrets or sensitive memories are returned.
    Do not invent memory records or imply an inaccessible memory was read.
    """
}
