import Foundation
import CoreData
import Combine

extension Notification.Name {
    static let assistantStoreReady = Notification.Name("ASSistantStoreReady")
}

final class Database {
    let container: NSPersistentCloudKitContainer
    private(set) var ready = false
    private(set) var syncMessage = "Loading local database"
    let cloudRequested: Bool

    init() {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Record"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        func field(_ key: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let property = NSAttributeDescription()
            property.name = key
            property.attributeType = type
            property.isOptional = true
            return property
        }
        entity.properties = [
            field("recordID", .stringAttributeType),
            field("kind", .stringAttributeType),
            field("payload", .binaryDataAttributeType),
            field("updatedAt", .dateAttributeType),
            field("deleted", .booleanAttributeType)
        ]
        model.entities = [entity]
        container = NSPersistentCloudKitContainer(name: "ASSistant", managedObjectModel: model)
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASSistant.sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        cloudRequested = UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true
        if cloudRequested {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.mekabrine.ASSistant"
            )
        }
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            if let error, self.cloudRequested {
                // Unsigned/sideloaded builds may lack functional CloudKit entitlements.
                // Open the SAME SQLite file locally rather than replacing the user's data.
                let fallback = NSPersistentStoreDescription(url: url)
                fallback.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                fallback.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
                self.container.persistentStoreDescriptions = [fallback]
                self.container.loadPersistentStores { [weak self] _, localError in
                    guard let self else { return }
                    let status = localError.map { "Local database failed: \($0.localizedDescription)" }
                        ?? "iCloud unavailable (\(error.localizedDescription)); using local data"
                    self.completeLoad(isReady: localError == nil, message: status)
                }
                return
            }
            let status = error.map { "Local database failed: \($0.localizedDescription)" }
                ?? (self.cloudRequested ? "iCloud sync configured (requires valid Apple signing/account)" : "Local-only mode")
            self.completeLoad(isReady: error == nil, message: status)
        }
    }

    private func completeLoad(isReady: Bool, message: String) {
        DispatchQueue.main.async {
            self.ready = isReady
            self.syncMessage = message
            if isReady { self.configureContext() }
            NotificationCenter.default.post(name: .assistantStoreReady, object: nil)
        }
    }

    private func configureContext() {
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func all<T: Decodable>(_ kind: String, as type: T.Type) -> [T] {
        guard ready else { return [] }
        let context = container.viewContext
        var result: [T] = []
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
            request.predicate = NSPredicate(format: "kind == %@ AND (deleted == NO OR deleted == nil)", kind)
            let objects = (try? context.fetch(request)) ?? []
            let decoder = JSONDecoder()
            result = objects.compactMap { object in
                guard let data = object.value(forKey: "payload") as? Data else { return nil }
                return try? decoder.decode(T.self, from: data)
            }
        }
        return result
    }

    func upsert<T: Encodable>(_ item: T, kind: String, id: UUID) {
        guard ready, let bytes = try? JSONEncoder().encode(item) else { return }
        let context = container.viewContext
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "kind == %@ AND recordID == %@", kind, id.uuidString)
            let object = ((try? context.fetch(request)) ?? []).first
                ?? NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
            object.setValue(id.uuidString, forKey: "recordID")
            object.setValue(kind, forKey: "kind")
            object.setValue(bytes, forKey: "payload")
            object.setValue(Date(), forKey: "updatedAt")
            object.setValue(false, forKey: "deleted")
            try? context.save()
        }
    }

    func remove(kind: String, id: UUID) {
        guard ready else { return }
        let context = container.viewContext
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
            request.predicate = NSPredicate(format: "kind == %@ AND recordID == %@", kind, id.uuidString)
            for object in ((try? context.fetch(request)) ?? []) {
                object.setValue(true, forKey: "deleted")
                object.setValue(Date(), forKey: "updatedAt")
            }
            try? context.save()
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    let database = Database()
    @Published var chats: [ChatThread] = []
    @Published var messages: [ChatMessage] = []
    @Published var providers: [ProviderProfile] = []
    @Published var agents: [AgentProfile] = []
    @Published var memories: [MemoryItem] = []
    @Published var summaries: [SessionSummary] = []
    @Published var tasks: [AgentTask] = []
    @Published var apps: [GeneratedApp] = []
    @Published var audits: [ToolAudit] = []
    @Published var syncStatus: String = "Loading"
    @Published var lastDiagnostic: ContextDiagnostic?
    private var observers: [NSObjectProtocol] = []

    init() {
        let readyObserver = NotificationCenter.default.addObserver(
            forName: .assistantStoreReady, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        let remoteObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        observers = [readyObserver, remoteObserver]
        reload()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func reload() {
        syncStatus = database.syncMessage
        guard database.ready else { return }
        chats = database.all("chat", as: ChatThread.self).sorted { $0.updatedAt > $1.updatedAt }
        messages = database.all("message", as: ChatMessage.self).sorted { $0.createdAt < $1.createdAt }
        providers = database.all("provider", as: ProviderProfile.self).sorted { $0.name < $1.name }
        agents = database.all("agent", as: AgentProfile.self).sorted { $0.name < $1.name }
        memories = database.all("memory", as: MemoryItem.self).sorted { $0.updatedAt > $1.updatedAt }
        summaries = database.all("summary", as: SessionSummary.self).sorted { $0.createdAt > $1.createdAt }
        tasks = database.all("task", as: AgentTask.self).sorted { $0.createdAt > $1.createdAt }
        apps = database.all("app", as: GeneratedApp.self).sorted { $0.updatedAt > $1.updatedAt }
        audits = database.all("audit", as: ToolAudit.self).sorted { $0.timestamp > $1.timestamp }
        if agents.isEmpty { save(AgentProfile(), kind: "agent") }
    }

    func save(_ chat: ChatThread) { save(chat, kind: "chat") }
    func save(_ message: ChatMessage) { save(message, kind: "message") }
    func save(_ provider: ProviderProfile) { save(provider, kind: "provider") }
    func save(_ agent: AgentProfile) { save(agent, kind: "agent") }
    func save(_ memory: MemoryItem) { save(memory, kind: "memory") }
    func save(_ summary: SessionSummary) { save(summary, kind: "summary") }
    func save(_ task: AgentTask) { save(task, kind: "task") }
    func save(_ app: GeneratedApp) { save(app, kind: "app") }
    func save(_ audit: ToolAudit) { save(audit, kind: "audit") }

    private func save<T: Codable & Identifiable>(_ value: T, kind: String) where T.ID == UUID {
        database.upsert(value, kind: kind, id: value.id)
        reloadSnapshot(kind: kind)
    }

    private func reloadSnapshot(kind: String) {
        // Refresh just the changed collection to avoid discarding transient UI state.
        switch kind {
        case "chat": chats = database.all(kind, as: ChatThread.self).sorted { $0.updatedAt > $1.updatedAt }
        case "message": messages = database.all(kind, as: ChatMessage.self).sorted { $0.createdAt < $1.createdAt }
        case "provider": providers = database.all(kind, as: ProviderProfile.self).sorted { $0.name < $1.name }
        case "agent": agents = database.all(kind, as: AgentProfile.self).sorted { $0.name < $1.name }
        case "memory": memories = database.all(kind, as: MemoryItem.self).sorted { $0.updatedAt > $1.updatedAt }
        case "summary": summaries = database.all(kind, as: SessionSummary.self).sorted { $0.createdAt > $1.createdAt }
        case "task": tasks = database.all(kind, as: AgentTask.self).sorted { $0.createdAt > $1.createdAt }
        case "app": apps = database.all(kind, as: GeneratedApp.self).sorted { $0.updatedAt > $1.updatedAt }
        case "audit": audits = database.all(kind, as: ToolAudit.self).sorted { $0.timestamp > $1.timestamp }
        default: break
        }
    }

    func delete(_ id: UUID, kind: String) {
        database.remove(kind: kind, id: id)
        reloadSnapshot(kind: kind)
    }

    func createChat(agentID: UUID? = nil) -> ChatThread {
        let chat = ChatThread(agentID: agentID)
        save(chat)
        return chat
    }

    func messages(in chatID: UUID) -> [ChatMessage] {
        messages.filter { $0.chatID == chatID }.sorted { $0.createdAt < $1.createdAt }
    }

    func provider(for chat: ChatThread) -> ProviderProfile? {
        if let id = agents.first(where: { $0.id == chat.agentID })?.providerID,
           let found = providers.first(where: { $0.id == id }) { return found }
        return providers.first(where: { $0.enabled })
    }

    func agent(for chat: ChatThread) -> AgentProfile {
        agents.first(where: { $0.id == chat.agentID }) ?? agents.first ?? AgentProfile()
    }

    func append(role: String, text: String, to chat: ChatThread) -> ChatMessage {
        var thread = chat
        thread.updatedAt = Date()
        if thread.title == "New Chat", role == "user" {
            thread.title = String(text.prefix(54)).replacingOccurrences(of: "\n", with: " ")
        }
        save(thread)
        let message = ChatMessage(chatID: chat.id, role: role, content: text)
        save(message)
        return message
    }
}
