import Foundation

/// A restorable, noncredential snapshot of one browser tab.
/// Page HTML, cookies, form values and security codes are intentionally excluded.
struct SavedBrowserTab: Codable, Identifiable {
    var id: UUID
    var url: String
    var title: String
    var pageExcerpt: String
    var scrollY: Double
    var visitedAt: Date
}

struct SavedChatBrowsers: Codable {
    var chatID: UUID
    var selectedTabID: UUID?
    var tabs: [SavedBrowserTab]
    var dockX: Double
    var dockY: Double
    var savedAt: Date
}

/// Local-only browser navigation state, stored separately for each chat.
/// Website login cookies are managed by WKWebsiteDataStore.default(), not here.
enum BrowserStateStore {
    static func folder() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("ChatBrowserState", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        var target = folder
        try? target.setResourceValues(options)
        return folder
    }

    static func file(for chatID: UUID) throws -> URL {
        try folder().appendingPathComponent(chatID.uuidString + ".json")
    }

    static func load(for chatID: UUID) -> SavedChatBrowsers? {
        guard let path = try? file(for: chatID),
              let bytes = try? Data(contentsOf: path),
              let saved = try? JSONDecoder().decode(SavedChatBrowsers.self, from: bytes),
              saved.chatID == chatID else { return nil }
        return saved
    }

    static func save(_ record: SavedChatBrowsers) {
        guard let path = try? file(for: record.chatID),
              let bytes = try? JSONEncoder().encode(record) else { return }
        do {
            try bytes.write(to: path, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            NSLog("ASSistant browser navigation was not saved: %@", error.localizedDescription)
        }
    }

    static func remove(for chatID: UUID) {
        if let path = try? file(for: chatID) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Never restore callback fragments or common OAuth/token query parameters.
    /// Only safe GET-style public HTTPS destinations are eligible for restoration.
    static func restorableURL(_ raw: String) -> String? {
        guard let checked = BrowserSession.safeURL(raw),
              var components = URLComponents(url: checked, resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = nil
        let sensitive = ["access_token", "id_token", "token", "refresh_token", "code",
                         "authorization", "state", "session", "session_id", "key",
                         "secret", "password", "otp", "nonce", "ticket", "auth"]
        components.queryItems = components.queryItems?.filter { item in
            let key = item.name.lowercased()
            return !sensitive.contains(where: { key == $0 || key.hasSuffix("_" + $0) })
        }
        // Avoid persisting sensitive callback addresses as well.
        let path = components.path.lowercased()
        if ["oauth/callback", "oauth2redirect", "auth/callback",
            "signin/callback", "sign-in/callback"].contains(where: path.contains) {
            return nil
        }
        return components.url?.absoluteString
    }
}
