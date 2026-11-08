import Foundation

/// Bounded, token-light memory browsing. Titles and IDs are supplied before
/// full contents, so a model can retrieve just the records it needs.
/// Sensitive records never enter the model automatically.
enum MemoryCatalogue {
    static let categories = [
        "fact", "preference", "goal", "project", "person",
        "decision", "routine", "procedure", "task", "timeline",
        "work", "hobby", "style", "food", "travel", "technology", "other"
    ]

    static func category(_ raw: String?) -> String {
        let cleaned = (raw ?? "").lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.contains(cleaned) ? cleaned : "fact"
    }

    static func label(_ item: MemoryItem) -> String {
        let single = item.text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(single.prefix(62)) + (single.count > 62 ? "…" : "")
    }

    static func list(_ items: [MemoryItem],
                     category: String? = nil,
                     period: String? = nil,
                     limit: Int = 40,
                     query: String? = nil) -> String {
        let category = (category ?? "").lowercased()
        let period = (period ?? "all").lowercased()
        let now = Date()
        let earliest: Date?
        switch period {
        case "week", "7d": earliest = Calendar.current.date(byAdding: .day, value: -7, to: now)
        case "month", "30d": earliest = Calendar.current.date(byAdding: .day, value: -30, to: now)
        case "year", "365d": earliest = Calendar.current.date(byAdding: .year, value: -1, to: now)
        default: earliest = nil
        }
        let matches = items.filter { item in
            guard !item.isSensitive, item.expiresAt.map({ $0 > now }) ?? true,
                  category.isEmpty || category == "all" || item.kind.lowercased() == category
            else { return false }
            if let earliest, item.createdAt < earliest { return false }
            if let query, !query.isEmpty {
                return item.text.localizedCaseInsensitiveContains(query) ||
                    item.kind.localizedCaseInsensitiveContains(query)
            }
            return true
        }.sorted { $0.createdAt > $1.createdAt }
        let rows = matches.prefix(min(80, max(1, limit))).map { item in
            let date = ISO8601DateFormatter().string(from: item.createdAt).prefix(10)
            return "ID: \(item.id.uuidString) | \(item.kind) | \(date) | \(label(item))"
        }
        return "Memories: \(matches.count) matching. Showing \(rows.count). " +
            "Ask memory_get with an exact ID to retrieve full information.\n" +
            (rows.isEmpty ? "(none)" : rows.joined(separator: "\n"))
    }

    static func get(_ items: [MemoryItem], id: String?) -> String {
        guard let id, let uuid = UUID(uuidString: id),
              let item = items.first(where: { $0.id == uuid && !$0.isSensitive }),
              item.expiresAt.map({ $0 > Date() }) ?? true
        else { return "Memory ID unavailable or private." }
        return """
        Memory ID: \(item.id.uuidString)
        Category: \(item.kind)
        Scope: \(item.scope)
        Importance: \(item.importance)
        Created: \(ISO8601DateFormatter().string(from: item.createdAt))
        Updated: \(ISO8601DateFormatter().string(from: item.updatedAt))
        Full memory: \(String(item.text.prefix(3000)))
        """
    }

    static let instructions = """
    Memory is long-term local data, NOT proof that every old fact remains true.
    Use tools to retrieve only relevant memories, not dump all of them:
    <assistant_tool>{"name":"memory_list","category":"preference","period":"month","limit":20}</assistant_tool>
    <assistant_tool>{"name":"memory_list","category":"all","period":"all","limit":30}</assistant_tool>
    <assistant_tool>{"name":"memory_search","query":"favorite clothing color","limit":20}</assistant_tool>
    <assistant_tool>{"name":"memory_get","memoryID":"EXACT_UUID_FROM_LIST"}</assistant_tool>
    Memory_list returns short titles, categories, dates and IDs; memory_get gives
    full text by ID. Use category (fact, preference, goal, project, person,
    decision, routine, work, hobby, style, food, travel, technology, other)
    and period (week, month, year, all). Sensitive memories are excluded.
    Do not invent a memory ID or reveal other users' information.
    """
}
