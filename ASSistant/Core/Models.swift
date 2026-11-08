import Foundation

struct ChatThread: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var agentID: UUID?
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var archived: Bool = false
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var chatID: UUID
    var role: String
    var content: String
    var createdAt: Date = .now
    var status: String = "complete"
    var estimatedInputTokens: Int = 0
    var estimatedOutputTokens: Int = 0
}

struct ProviderProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "Custom provider"
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = ""
    var adapter: String = "openai"
    var authMode: String = "bearer"
    var apiKeyHeader: String = "x-api-key"
    var maxContextTokens: Int = 8192
    var maxOutputTokens: Int = 1024
    var temperature: Double = 0.7
    var enabled: Bool = true
}

struct AgentProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = "General Assistant"
    var instructions: String = "Be useful, precise, and respect explicit user approval for real-world actions. Offer reusable HTMLApp apps only when a persistent interface would benefit the user."
    var providerID: UUID?
    var allowedTools: [String] = ["reminder", "calendar", "contacts", "location", "clipboard", "notification", "htmlapp", "web", "memory", "shortcuts", "sms", "phone", "gmail", "spotify", "speak", "memory"]
}

struct MemoryItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var title: String? = nil
    var category: String? = nil
    var kind: String = "fact"
    var scope: String = "global"
    var sourceMessageID: UUID?
    var importance: Double = 0.5
    var pinned: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var lastUsedAt: Date?
    var expiresAt: Date?
    var isSensitive: Bool = false
}

struct SessionSummary: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var chatID: UUID
    var throughMessageID: UUID?
    var coveredCount: Int
    var text: String
    var createdAt: Date = .now
}

struct AgentTask: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var details: String = ""
    var state: String = "open"
    var dueDate: Date?
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

struct GeneratedApp: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var prompt: String
    var html: String
    var sourceURL: String?
    var chatID: UUID? = nil
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var version: Int = 1
}

struct ToolAudit: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var tool: String
    var detail: String
    var approved: Bool
    var result: String
    var timestamp: Date = .now
}

struct ContextDiagnostic: Identifiable {
    let id = UUID()
    var inputTokens: Int
    var contextTokens: Int
    var memoriesUsed: Int
    var messagesUsed: Int
    var summaryUsed: Bool
}

struct LLMMessage: Codable {
    var role: String
    var content: String
}
