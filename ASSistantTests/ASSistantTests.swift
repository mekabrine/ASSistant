import XCTest
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
}
