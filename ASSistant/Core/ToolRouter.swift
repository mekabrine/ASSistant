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
    var recipient: String?
    var subject: String?
    var query: String?
    var uri: String?
    var browserID: String?
    var category: String?
    var memoryID: String?
    var days: Int?

    enum CodingKeys: String, CodingKey { case name, title, details, text, at, end, url, linkID, site, recipient, subject, query, uri, browserID, category, memoryID, days }
}

enum ToolRouter {
    static let names = [
        "create_reminder", "create_calendar_event", "schedule_notification",
        "get_location", "count_contacts", "copy_text", "speak_text", "create_task",
        "browser_search", "browser_open", "browser_read", "browser_follow",
        "browser_fill_search", "browser_submit_search", "browser_scroll",
        "browser_new", "browser_switch", "browser_tabs", "browser_request_handoff",
        "gmail_search", "gmail_read", "spotify_search", "spotify_now_playing",
        "spotify_playlists", "gmail_send",
        "spotify_play", "spotify_pause", "spotify_next", "spotify_previous",
        "run_shortcut", "place_call", "compose_sms", "find_contacts"
    ]

    static let automaticAccountReads: Set<String> = [
        "gmail_search", "gmail_read", "spotify_search",
        "spotify_now_playing", "spotify_playlists"
    ]

    static func category(for name: String) -> String {
        switch name {
        case "gmail_search", "gmail_read", "gmail_send": return "gmail"
        case "spotify_search", "spotify_now_playing", "spotify_playlists",
             "spotify_play", "spotify_pause", "spotify_next", "spotify_previous": return "spotify"
        case "run_shortcut": return "shortcuts"
        case "place_call": return "phone"
        case "compose_sms": return "sms"
        case "find_contacts", "count_contacts": return "contacts"
        case "create_reminder": return "reminder"
        case "create_calendar_event": return "calendar"
        case "schedule_notification": return "notification"
        case "get_location": return "location"
        case "copy_text": return "clipboard"
        case "speak_text": return "speak"
        case "create_task": return "task"
        default: return name.hasPrefix("browser_") ? "web" : "unknown"
        }
    }

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
        case "run_shortcut":
            return try await NativeActions.runShortcut(name: call.title ?? "",
                                                       input: call.text)
        case "place_call":
            return try await NativeActions.openPhone(call.recipient ?? "")
        case "find_contacts":
            return try await NativeActions.contactMatches(call.query ?? call.title ?? "")
        case "gmail_send":
            return try await GmailService.send(to: call.recipient ?? "",
                                               subject: call.subject ?? "",
                                               body: call.text ?? "")
        case "spotify_play", "spotify_pause", "spotify_next", "spotify_previous":
            return try await SpotifyService.playerAction(call.name, trackURI: call.uri)
        default: throw DeviceToolError.unavailable
        }
    }
}

extension MemoryEngine {
    static let agentToolInstructions = """
    You are an actionable assistant, not a search-terms-only bot. Use real
    tools when available. Never claim a tool finished unless the OS/API confirmed it.

    Native/external write actions require one explicit user approval.
    Propose exactly ONE action as JSON between <assistant_tool> tags:
    <assistant_tool>{"name":"run_shortcut","title":"My Shortcut Name","text":"optional input"}</assistant_tool>
    <assistant_tool>{"name":"place_call","recipient":"+15551234567"}</assistant_tool>
    <assistant_tool>{"name":"compose_sms","recipient":"+15551234567","text":"Hello"}</assistant_tool>
    <assistant_tool>{"name":"find_contacts","query":"Sam"}</assistant_tool>
    <assistant_tool>{"name":"gmail_send","recipient":"person@example.com","subject":"Hello","text":"Message body"}</assistant_tool>
    <assistant_tool>{"name":"spotify_play","uri":"spotify:track:TRACKID"}</assistant_tool>
    <assistant_tool>{"name":"spotify_pause"}</assistant_tool>
    <assistant_tool>{"name":"spotify_next"}</assistant_tool>
    Other native actions: create_reminder, create_calendar_event,
    schedule_notification, get_location, count_contacts, copy_text,
    speak_text, create_task.

    When the user asks to run a Shortcut, open the Shortcuts URL rather than
    giving only instructions. Shortcut names must match installed Shortcuts,
    and completion is NOT visible to ASSistant. You cannot list arbitrary
    iOS Shortcuts without a user-installed integration.
    When calling someone, request an actual phone number or a contact lookup.
    When texting, prepare a Messages composer; the USER must tap Send.
    Sending Gmail is an external account change and ALWAYS requires explicit approval.
    Spotify playback changes require approval and may require Premium.

    Don't fabricate Gmail mail content, Spotify tracks, send confirmations or calls.
    Never expose saved credentials, OAuth tokens or account secrets.
    If a mini-app is useful, propose [[BUILD_HTMLAPP]] and wait for approval.
    """
}
