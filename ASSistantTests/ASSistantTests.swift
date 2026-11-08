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
        XCTAssertFalse(AgentEngine.shouldSearchImmediately("Find my passwords in my files"))
        XCTAssertFalse(AgentEngine.shouldSearchImmediately("Search my contacts for a phone number"))
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

    func testAccountToolsArePermissionCategorized() {
        XCTAssertTrue(ToolRouter.automaticAccountReads.contains("gmail_search"))
        XCTAssertFalse(ToolRouter.automaticAccountReads.contains("gmail_send"))
        XCTAssertTrue(ToolRouter.automaticAccountReads.contains("spotify_now_playing"))
        XCTAssertFalse(ToolRouter.automaticAccountReads.contains("spotify_pause"))
        XCTAssertEqual(ToolRouter.category(for: "gmail_send"), "gmail")
        XCTAssertEqual(ToolRouter.category(for: "place_call"), "phone")
        XCTAssertEqual(ToolRouter.category(for: "run_shortcut"), "shortcuts")
        XCTAssertEqual(ToolRouter.category(for: "compose_sms"), "sms")
    }

    @MainActor
    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(ConnectedServices.pkceChallenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testConnectedToolPayloadDecoding() {
        let gmail = ToolRouter.extract(from:
            #"<assistant_tool>{"name":"gmail_search","query":"is:unread newer_than:2d"}</assistant_tool>"#)
        XCTAssertEqual(gmail?.query, "is:unread newer_than:2d")
        let message = ToolRouter.extract(from:
            #"<assistant_tool>{"name":"compose_sms","recipient":"+19995550101","text":"Hello"}</assistant_tool>"#)
        XCTAssertEqual(message?.name, "compose_sms")
        XCTAssertEqual(message?.recipient, "+19995550101")
        let shortcut = ToolRouter.extract(from:
            #"<assistant_tool>{"name":"run_shortcut","title":"Start Work"}</assistant_tool>"#)
        XCTAssertEqual(shortcut?.title, "Start Work")
    }

    @MainActor
    func testCallDestinationInputValidation() {
        XCTAssertEqual(try NativeActions.cleanPhone("+1 (999) 555-0101"), "+19995550101")
        XCTAssertThrowsError(try NativeActions.cleanPhone("not a phone number"))
        XCTAssertThrowsError(try NativeActions.cleanPhone("123"))
    }

    func testConnectedAccountLookupRequiresUserIntent() {
        XCTAssertTrue(AccountAgentTools.userRequested("gmail",
            prompt: "Search my Gmail for a delivery confirmation"))
        XCTAssertTrue(AccountAgentTools.userRequested("spotify",
            prompt: "What's now playing on Spotify?"))
        XCTAssertFalse(AccountAgentTools.userRequested("gmail",
            prompt: "What is the weather today?"))
        XCTAssertFalse(AccountAgentTools.userRequested("spotify",
            prompt: "Find me a navy blue apron on Amazon"))
    }

    func testOAuthProviderConfiguration() {
        XCTAssertEqual(ConnectedServiceKind.google.callbackScheme, "com.mekabrine.assistant")
        XCTAssertEqual(ConnectedServiceKind.spotify.callbackScheme, "assistantspotify")
        XCTAssertTrue(ConnectedServiceKind.google.scopes.contains("gmail.readonly"))
        XCTAssertTrue(ConnectedServiceKind.google.scopes.contains("gmail.send"))
        XCTAssertTrue(ConnectedServiceKind.spotify.scopes.contains("user-read-playback-state"))
    }

    func testRegisteredOAuthSchemesInAppBundle() {
        let entries = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
            as? [[String: Any]] ?? []
        let schemes = entries.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("com.mekabrine.assistant"),
                      "Google auth callback scheme must be in generated Info.plist")
        XCTAssertTrue(schemes.contains("assistantspotify"),
                      "Spotify auth callback scheme must be in generated Info.plist")
    }

    func testMemoryDirectoryTitlesCategoriesAndDates() {
        let chat = ChatThread()
        let agent = AgentProfile()
        var favorite = MemoryItem(text: "I love navy blue work aprons", kind: "preference")
        favorite.title = "Navy blue work aprons"
        favorite.category = "Preferences"
        var project = MemoryItem(text: "Our prototype uses iOS SwiftUI", kind: "project")
        project.category = "Projects"
        var secret = MemoryItem(text: "Private secret", kind: "fact", isSensitive: true)
        secret.category = "Personal"
        let entries = [favorite, project, secret]
        let directory = MemoryDirectory.list(entries, chat: chat, agent: agent,
                                              category: "Preferences", days: 30)
        XCTAssertTrue(directory.contains("Navy blue work aprons"))
        XCTAssertTrue(directory.contains(favorite.id.uuidString))
        XCTAssertFalse(directory.contains("prototype"))
        XCTAssertFalse(directory.contains("Private secret"))
        let detail = MemoryDirectory.get(favorite.id.uuidString, memories: entries,
                                         chat: chat, agent: agent)
        XCTAssertTrue(detail.contains("I love navy blue work aprons"))
        XCTAssertFalse(MemoryDirectory.get(secret.id.uuidString, memories: entries,
                                           chat: chat, agent: agent).contains("Private secret"))
    }

    func testAutomaticPreferenceExtraction() {
        let chatID = UUID(), msgID = UUID()
        let items = MemoryEngine.candidates(from: "I love navy blue work aprons",
                                            messageID: msgID, chatID: chatID)
        XCTAssertEqual(items.first?.category, "Preferences")
        XCTAssertEqual(items.first?.scope, "global")
        XCTAssertNotNil(items.first?.title)
        XCTAssertTrue(MemoryEngine.candidates(from: "My password is 123456",
                                             messageID: msgID, chatID: chatID).isEmpty)
    }

    @MainActor
    func testChatTitleCadenceAndFallback() {
        XCTAssertTrue(ChatTitleService.shouldRename(count: 2))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 5))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 10))
        XCTAssertFalse(ChatTitleService.shouldRename(count: 3))
    }

    func testRichMessageBlocksAndSafePreview() {
        let fence = MessageFormatter.fence
        let content = """
        | Name | Price |
        | --- | --- |
        | Apron | 15 |

        \(fence)swift
        let n = 2
        \(fence)
        """
        let parts = MessageFormatter.parse(content)
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertTrue(MessageFormatter.allowedPreview("<html><body>Hi</body></html>"))
        XCTAssertFalse(MessageFormatter.allowedPreview("<script>alert(1)</script>"))
        XCTAssertFalse(MessageFormatter.allowedPreview("<img src=https://example.com/a>"))
    }

    @MainActor
    func testBrowserChallengeDetectionAndMultipleSessions() {
        XCTAssertTrue(BrowserSession.looksLikeChallenge("Verify that you are human"))
        XCTAssertTrue(BrowserSession.looksLikeChallenge("Our systems have detected unusual traffic"))
        XCTAssertFalse(BrowserSession.looksLikeChallenge("Navy blue apron in stock"))
        let workspace = BrowserWorkspace()
        let first = workspace.active.id
        let second = workspace.newBrowser().id
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(workspace.sessions.count, 2)
        workspace.select(first)
        XCTAssertEqual(workspace.active.id, first)
        workspace.requestHuman("Enter a security code")
        XCTAssertTrue(workspace.active.userControl)
        workspace.takeBackControl()
        XCTAssertFalse(workspace.active.userControl)
    }

    func testVoiceCallProgressIsBrief() {
        let phrase = VoiceCallProgress.shortPhrase(for: "Browser: browser_follow")
        XCTAssertNotNil(phrase)
        XCTAssertLessThanOrEqual(phrase!.split(separator: " ").count, 8)
    }

    func testMemoryDirectoryCategoriesRecencyAndExactID() {
        let chat = ChatThread()
        let agent = AgentProfile()
        var recent = MemoryItem(text: "I like navy blue aprons", kind: "preference")
        recent.category = "Preferences"
        recent.title = "Navy blue apron preference"
        var old = MemoryItem(text: "I used to prefer red aprons", kind: "preference")
        old.category = "Preferences"
        old.updatedAt = Date().addingTimeInterval(-70 * 86400)
        var privateMemory = MemoryItem(text: "A secret password", kind: "fact")
        privateMemory.isSensitive = true
        let all = [recent, old, privateMemory]
        let recentIndex = MemoryDirectory.list(all, chat: chat, agent: agent,
                                               category: "Preferences", days: 30)
        XCTAssertTrue(recentIndex.contains(recent.id.uuidString))
        XCTAssertFalse(recentIndex.contains(old.id.uuidString))
        XCTAssertFalse(recentIndex.contains(privateMemory.id.uuidString))
        let full = MemoryDirectory.get(recent.id.uuidString, memories: all, chat: chat, agent: agent)
        XCTAssertTrue(full.contains("navy blue aprons"))
        XCTAssertFalse(MemoryDirectory.get(privateMemory.id.uuidString, memories: all,
                                          chat: chat, agent: agent).contains("secret password"))
    }

    @MainActor
    func testBrowserCAPTCHAFallbackDetector() {
        XCTAssertTrue(BrowserSession.looksLikeChallenge(
            "Our systems have detected unusual traffic from your computer network"))
        XCTAssertTrue(BrowserSession.looksLikeChallenge("Please verify you are a human"))
        XCTAssertFalse(BrowserSession.looksLikeChallenge(
            "A store listing several navy blue aprons at different prices"))
    }

    func testChatMessageFormattingParts() {
        let sample = "| Item | Price |\n| --- | --- |\n| Apron | $19 |\n\n" +
            "Here is an example:\n" +
            MessageFormatter.fence + "swift\nprint(123)\n" + MessageFormatter.fence
        let parts = MessageFormatter.parse(sample)
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        let choice = "<assistant_choices>{\"question\":\"Pick one\",\"options\":[\"A\",\"B\"]}</assistant_choices>"
        XCTAssertEqual(MessageFormatter.parse(choice).count, 1)
        XCTAssertTrue(MessageFormatter.allowedPreview("<div>Hello</div>"))
        XCTAssertFalse(MessageFormatter.allowedPreview("<script>fetch('/token')</script>"))
    }

    @MainActor
    func testTitleGenerationCadence() {
        XCTAssertTrue(ChatTitleService.shouldRename(count: 1))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 5))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 10))
        XCTAssertFalse(ChatTitleService.shouldRename(count: 7))
        XCTAssertEqual(ChatTitleService.fallback("Find me a navy blue apron on Amazon"),
                       "Find me a navy blue apron on")
    }

    func testMemoryDirectoryCategoriesPeriodAndID() {
        let chat = ChatThread()
        let agent = AgentProfile()
        var pref = MemoryItem(text: "I prefer dark blue aprons", kind: "preference")
        pref.title = "Work apron colors"
        pref.category = "Preferences"
        var privateMemory = MemoryItem(text: "I prefer not to share this", kind: "preference")
        privateMemory.isSensitive = true
        let directory = MemoryDirectory.list([pref, privateMemory], chat: chat, agent: agent,
                                             category: "Preferences", days: 30)
        XCTAssertTrue(directory.contains("Work apron colors"))
        XCTAssertTrue(directory.contains(pref.id.uuidString))
        XCTAssertFalse(directory.contains(privateMemory.id.uuidString))
        let full = MemoryDirectory.get(pref.id.uuidString, memories: [pref],
                                       chat: chat, agent: agent)
        XCTAssertTrue(full.contains("dark blue aprons"))
        XCTAssertFalse(MemoryDirectory.get(privateMemory.id.uuidString,
                                          memories: [privateMemory], chat: chat, agent: agent)
            .contains("prefer not to share"))
    }

    @MainActor
    func testBrowserVerificationDetectionAndSearchSafety() {
        XCTAssertTrue(BrowserSession.needsHuman("Please enter the verification code"))
        XCTAssertTrue(BrowserSession.looksLikeChallenge("verify you are human"))
        XCTAssertFalse(BrowserSession.needsHuman("Compare two blue aprons"))
        XCTAssertNil(BrowserSession.safeURL("http://localhost/password"))
    }

    @MainActor
    func testChatTitleScheduleAndAppIntent() {
        XCTAssertTrue(ChatTitleService.shouldRename(count: 1))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 5))
        XCTAssertTrue(ChatTitleService.shouldRename(count: 10))
        XCTAssertFalse(ChatTitleService.shouldRename(count: 7))
    }

    func testRichContentSupportsTablesChoicesAndCodeBlocks() {
        let table = "| Item | Color |\n| --- | --- |\n| Apron | Navy |"
        XCTAssertEqual(MessageFormatter.parse(table).count, 1)
        let choices = #"<assistant_choices>{"question":"Choose a color","options":["Navy","Black"]}</assistant_choices>"#
        XCTAssertEqual(MessageFormatter.parse(choices).count, 1)
        XCTAssertFalse(MessageFormatter.allowedPreview("<script>alert(1)</script>"))
        XCTAssertTrue(MessageFormatter.allowedPreview("<div>Ready</div>"))
    }

    @MainActor
    func testChatBrowserStateRestoresSeparatePages() throws {
        let firstID = UUID()
        let secondID = UUID()
        defer {
            BrowserStateStore.remove(for: firstID)
            BrowserStateStore.remove(for: secondID)
        }
        let tab = SavedBrowserTab(id: UUID(), url: "https://example.com/page",
                                  title: "Saved example", pageExcerpt: "Visible page details",
                                  scrollY: 220, visitedAt: .now)
        BrowserStateStore.save(SavedChatBrowsers(
            chatID: firstID, selectedTabID: tab.id, tabs: [tab],
            dockX: 0.25, dockY: 0.55, savedAt: .now
        ))
        BrowserStateStore.save(SavedChatBrowsers(
            chatID: secondID, selectedTabID: nil, tabs: [],
            dockX: 0.8, dockY: 0.4, savedAt: .now
        ))
        let first = try XCTUnwrap(BrowserStateStore.load(for: firstID))
        let second = try XCTUnwrap(BrowserStateStore.load(for: secondID))
        XCTAssertEqual(first.tabs.first?.title, "Saved example")
        XCTAssertEqual(first.tabs.first?.scrollY, 220)
        XCTAssertEqual(first.selectedTabID, tab.id)
        XCTAssertEqual(second.tabs.count, 0)
        XCTAssertEqual(second.dockX, 0.8)
    }

    @MainActor
    func testBrowserRestoreURLRejectsAuthTokensAndUnsafeDestinations() {
        let restored = BrowserStateStore.restorableURL(
            "https://example.com/search?q=apron&access_token=secret&state=abc"
        )
        XCTAssertEqual(restored, "https://example.com/search?q=apron")
        XCTAssertNil(BrowserStateStore.restorableURL("http://example.com/search"))
        XCTAssertNil(BrowserStateStore.restorableURL(
            "https://example.com/oauth/callback?code=abc"))
    }

    func testLocalDraftsAreChatSpecific() {
        let first = UUID()
        let second = UUID()
        defer {
            ChatDraftStore.remove(first)
            ChatDraftStore.remove(second)
        }
        ChatDraftStore.put("A long unsent message", for: first)
        ChatDraftStore.put("Another draft", for: second)
        XCTAssertEqual(ChatDraftStore.get(first), "A long unsent message")
        XCTAssertEqual(ChatDraftStore.get(second), "Another draft")
        ChatDraftStore.remove(first)
        XCTAssertTrue(ChatDraftStore.get(first).isEmpty)
        XCTAssertEqual(ChatDraftStore.get(second), "Another draft")
    }

}
