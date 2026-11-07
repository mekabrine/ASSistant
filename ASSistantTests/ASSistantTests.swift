import XCTest
import CoreData
@testable import ASSistant

final class ASSistantTests: XCTestCase {
    func testHTMLAppImportURL() throws {
        let url = try HTMLAppBuilder.installURL(
            for: "https://gist.githubusercontent.com/example/abc/raw/app.html"
        )
        XCTAssertEqual(url.scheme, "htmlapp")
        XCTAssertEqual(url.host, "import")
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertEqual(source, "https://gist.githubusercontent.com/example/abc/raw/app.html")
    }

    func testRejectsUnsafeImportURL() {
        XCTAssertThrowsError(try HTMLAppBuilder.installURL(for: "http://localhost/app.html"))
        XCTAssertThrowsError(try HTMLAppBuilder.installURL(for: "file:///tmp/secret.html"))
    }

    func testOnlyRelevantMemoryIncludedInContext() {
        let chat = ChatThread()
        let msg = ChatMessage(chatID: chat.id, role: "user", content: "What is my HTMLApp deployment plan?")
        let a = MemoryItem(text: "HTMLApp apps should use the htmlapp import URL", kind: "project")
        let b = MemoryItem(text: "My preferred color is green", kind: "preference")
        let sensitive = MemoryItem(text: "HTMLApp secret password is abc", kind: "fact", isSensitive: true)
        var profile = ProviderProfile()
        profile.model = "test-model"
        let prepared = MemoryEngine.context(
            chat: chat, allMessages: [msg], agent: AgentProfile(),
            profile: profile, memories: [a, b, sensitive], summaries: []
        )
        let body = prepared.messages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(body.contains("HTMLApp apps"))
        XCTAssertFalse(body.contains("My preferred color"))
        XCTAssertFalse(body.contains("secret password"))
        XCTAssertLessThanOrEqual(prepared.diagnostic.inputTokens, profile.maxContextTokens)
    }

    func testMemoryDeduplication() {
        let fact = MemoryItem(text: "Remember project uses a single HTML file")
        XCTAssertTrue(MemoryEngine.containsSimilar(fact, in: [fact]))
    }

    func testSkillNormalization() throws {
        let html = "<!doctype html><html><head><title>Test</title></head><body><script>let n = 1;</script></body></html>"
        XCTAssertEqual(try HTMLAppBuilder.normalizedHTML("```html\n" + html + "\n```"), html)
        XCTAssertThrowsError(try HTMLAppBuilder.normalizedHTML("not an app"))
    }

    func testToolCallsNeverExecuteWithoutApproval() {
        let proposal = ToolRouter.extract(from:
            "I can add a reminder. <assistant_tool>{\"name\":\"create_reminder\",\"title\":\"Buy milk\"}</assistant_tool>")
        XCTAssertEqual(proposal?.name, "create_reminder")
        XCTAssertNil(ToolRouter.extract(from: "Created a reminder!"))
    }
    func testCoreDataLaunchModelHasNonReservedTombstone() throws {
        let model = Database.makeModel()
        let entity = try XCTUnwrap(model.entitiesByName["Record"])
        XCTAssertNotNil(entity.attributesByName["tombstoneFlag"])
        XCTAssertNil(entity.attributesByName["deleted"],
                     "Using NSManagedObject's built-in deletion property can crash KVC at startup.")

        let container = NSPersistentContainer(name: "ASSistantModelSmokeTest", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var openingError: Error?
        container.loadPersistentStores { _, error in openingError = error }
        XCTAssertNil(openingError)
        let context = container.viewContext
        let item = NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
        item.setValue("test", forKey: "kind")
        item.setValue("0001", forKey: "recordID")
        item.setValue(false, forKey: "tombstoneFlag")
        try context.save()
        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        request.predicate = NSPredicate(format: "kind == %@ AND tombstoneFlag == NO", "test")
        XCTAssertEqual(try context.fetch(request).count, 1)
    }

    @MainActor
    func testShoppingRequestsReallyTriggerWebSearch() {
        XCTAssertTrue(AgentEngine.shouldSearchImmediately(
            "Search on Amazon and find me a navy blue apron"
        ))
        XCTAssertTrue(AgentEngine.shouldSearchImmediately("Compare products online"))
        XCTAssertFalse(AgentEngine.shouldSearchImmediately("Remember my preferred apron color"))
    }

    @MainActor
    func testBrowserOnlyAcceptsPublicHTTPS() {
        XCTAssertNotNil(BrowserSession.safeURL("https://www.amazon.com/s?k=navy+blue+apron"))
        XCTAssertNil(BrowserSession.safeURL("http://example.com"))
        XCTAssertNil(BrowserSession.safeURL("https://localhost/account"))
        XCTAssertNil(BrowserSession.safeURL("https://127.0.0.1/password"))
        XCTAssertNil(BrowserSession.safeURL("file:///private/documents"))
        XCTAssertNil(BrowserSession.safeURL("https://user:pass@example.com"))
    }

    func testPublishedHTMLCannotContainLiteralCredentials() {
        XCTAssertThrowsError(try HTMLPublisher.verifyPublicHTML(
            "<html><script>const token='ghp_1234567890123456789012345'</script></html>"
        ))
        XCTAssertNoThrow(try HTMLPublisher.verifyPublicHTML(
            "<!doctype html><html><body><script>localStorage.setItem('note','hello')</script></body></html>"
        ))
    }

    func testSupersededMessagesRemainStoredButDoNotEnterContext() {
        let chat = ChatThread()
        let original = ChatMessage(chatID: chat.id, role: "user",
                                   content: "Remember my obsolete message.",
                                   status: "superseded")
        let latest = ChatMessage(chatID: chat.id, role: "user",
                                 content: "Find a navy apron online.")
        var provider = ProviderProfile()
        provider.model = "any"
        let prepared = MemoryEngine.context(chat: chat, allMessages: [original, latest],
                                            agent: AgentProfile(), profile: provider,
                                            memories: [], summaries: [])
        let transmitted = prepared.messages.map(\.content).joined(separator: "\n")
        XCTAssertFalse(transmitted.contains("obsolete message"))
        XCTAssertTrue(transmitted.contains("navy apron"))
    }

}
