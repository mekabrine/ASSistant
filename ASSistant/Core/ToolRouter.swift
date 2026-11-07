import Foundation

struct ProposedTool: Codable, Identifiable {
    var id = UUID()
    var name: String
    var title: String?
    var details: String?
    var text: String?
    var at: String?
    var end: String?
    var url: String?
    var linkID: String?
    var site: String?

    enum CodingKeys: String, CodingKey { case name, title, details, text, at, end, url, linkID, site }
}

enum ToolRouter {
    static let names = ["create_reminder", "create_calendar_event", "schedule_notification",
                        "get_location", "count_contacts", "copy_text", "speak_text", "create_task",
                        "browser_search", "browser_open", "browser_read", "browser_follow"]
    static func extract(from response: String) -> ProposedTool? {
        guard let start = response.range(of: "<assistant_tool>"),
              let end = response.range(of: "</assistant_tool>", range: start.upperBound..<response.endIndex),
              let data = String(response[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let request = try? JSONDecoder().decode(ProposedTool.self, from: data),
              names.contains(request.name) else { return nil }
        return request
    }

    static func cleanedResponse(_ text: String) -> String {
        guard let start = text.range(of: "<assistant_tool>"),
              let end = text.range(of: "</assistant_tool>", range: start.upperBound..<text.endIndex) else { return text }
        var content = text
        content.removeSubrange(start.lowerBound..<end.upperBound)
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "I can perform this action after you approve it." : cleaned
    }

    static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)
            ?? ISO8601DateFormatter().date(from: text + "T12:00:00Z")
    }

    @MainActor
    static func execute(_ call: ProposedTool, store: AppStore) async throws -> String {
        let tools = DeviceTools.shared
        switch call.name {
        case "create_reminder":
            let title = call.title ?? ""
            try await tools.createReminder(title: title, notes: call.details ?? "", due: isoDate(call.at))
            return "Reminder created: \(title)"
        case "create_calendar_event":
            guard let start = isoDate(call.at), let end = isoDate(call.end) else { throw DeviceToolError.missingInput }
            try await tools.createCalendarEvent(title: call.title ?? "", start: start, end: end)
            return "Calendar event created: \(call.title ?? "")"
        case "schedule_notification":
            guard let when = isoDate(call.at), when > .now else { throw DeviceToolError.missingInput }
            try await tools.scheduleNotification(id: call.id, title: call.title ?? "ASSistant", body: call.details ?? "", at: when)
            return "Local notification scheduled: \(call.title ?? "ASSistant")"
        case "get_location":
            let place = try await tools.currentLocation()
            return "Current coordinates: \(place.coordinate.latitude), \(place.coordinate.longitude) (accuracy \(Int(place.horizontalAccuracy)) m)"
        case "count_contacts":
            return "Accessible contacts: \(try await tools.contactsCount())"
        case "copy_text":
            tools.copyToClipboard(call.text ?? "")
            return "Copied text to clipboard."
        case "speak_text":
            tools.speak(call.text ?? "")
            return "Started speaking the requested text."
        case "create_task":
            let title = call.title ?? ""
            guard !title.isEmpty else { throw DeviceToolError.missingInput }
            store.save(AgentTask(title: title, details: call.details ?? "", dueDate: isoDate(call.at)))
            return "Created ASSistant task: \(title)"
        default: throw DeviceToolError.unavailable
        }
    }
}

extension MemoryEngine {
    static let agentToolInstructions = """
    Device tools require explicit user approval. If the user asks for an actual action and one of
    the following tools fits, propose exactly ONE tool call at the end of your reply as XML-like text:
    <assistant_tool>{"name":"create_reminder","title":"Buy milk","at":"2027-01-10T17:00:00Z"}</assistant_tool>
    Supported names: create_reminder, create_calendar_event, schedule_notification,
    get_location, count_contacts, copy_text, speak_text, create_task.
    Optional fields: title, details, text, at, end. Dates must be full ISO8601 with timezone.
    Request confirmation rather than claiming success. Do NOT include tool calls in quoted code examples.
    If a persistent app would be more useful, offer HTMLApp creation and end with [[BUILD_HTMLAPP]]
    only as a suggestion. Do not claim it was built until it was generated and published.
    """
}
