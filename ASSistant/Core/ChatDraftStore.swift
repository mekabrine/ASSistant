import Foundation

/// Unsent text is local per conversation, not included in model requests,
/// memory extraction, or any cloud browser-state synchronization.
enum ChatDraftStore {
    private static func file(_ chatID: UUID) -> URL? {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = root.appendingPathComponent("ConversationDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var folderToUpdate = folder
        try? folderToUpdate.setResourceValues(resource)
        return folder.appendingPathComponent(chatID.uuidString + ".txt")
    }

    static func get(_ chatID: UUID) -> String {
        guard let url = file(chatID),
              let bytes = try? Data(contentsOf: url),
              let result = String(data: bytes, encoding: .utf8) else { return "" }
        return String(result.prefix(50000))
    }

    static func put(_ draft: String, for chatID: UUID) {
        guard let url = file(chatID) else { return }
        if draft.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = String(draft.prefix(50000)).data(using: .utf8) {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    static func remove(_ chatID: UUID) {
        guard let url = file(chatID) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
