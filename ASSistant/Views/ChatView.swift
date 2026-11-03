import SwiftUI
import UniformTypeIdentifiers

private struct BuildPrompt: Identifiable {
    let id = UUID()
    var text: String
}

@MainActor
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var chatID: UUID?
    @State private var composer = ""
    @State private var streaming = ""
    @State private var errorText = ""
    @State private var isLoading = false
    @State private var showChats = false
    @State private var importFile = false
    @State private var buildPrompt: BuildPrompt?
    @State private var pendingTool: ProposedTool?
    @State private var toolAlert = false
    @State private var task: Task<Void, Never>?
    @AppStorage("autoSummaryEnabled") private var autoSummaryEnabled = false

    private var current: ChatThread? { store.chats.first(where: { $0.id == chatID }) }
    private var currentMessages: [ChatMessage] {
        guard let chatID else { return [] }
        return store.messages(in: chatID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let current {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(currentMessages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                                if isLoading {
                                    HStack(alignment: .top) {
                                        Text(streaming.isEmpty ? "Thinking…" : streaming)
                                            .textSelection(.enabled)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                                        Spacer(minLength: 30)
                                    }
                                    .id("stream")
                                }
                                if !errorText.isEmpty {
                                    Text(errorText).font(.footnote).foregroundColor(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding()
                        }
                        .onChange(of: currentMessages.count) { _ in
                            if let last = currentMessages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: streaming) { _ in
                            proxy.scrollTo("stream", anchor: .bottom)
                        }
                    }
                    if let d = store.lastDiagnostic {
                        HStack {
                            Text("Context: ~\(d.inputTokens) tokens · \(d.memoriesUsed) memories · \(d.messagesUsed) turns")
                            Spacer()
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                    composerArea
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle)
                        Text(store.database.ready ? "Start a conversation" : "Opening your library…")
                        Button("New Chat") { newChat() }.disabled(!store.database.ready)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(current?.title ?? "ASSistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "line.3.horizontal") }
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Generate HTMLApp") {
                            buildPrompt = BuildPrompt(text: composer.isEmpty ? "Build a useful app based on this chat: " + currentMessages.suffix(5).map(\.content).joined(separator: "\n") : composer)
                        }
                        Button("Read last answer aloud") {
                            if let last = currentMessages.last(where: { $0.role == "assistant" }) {
                                DeviceTools.shared.speak(last.content)
                            }
                        }
                        Button("Stop speaking") { DeviceTools.shared.stopSpeaking() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showChats) {
                ChatPicker(selected: $chatID)
                    .environmentObject(store)
            }
            .sheet(item: $buildPrompt) { prompt in
                AppBuilderScreen(initialPrompt: prompt.text)
                    .environmentObject(store)
            }
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.plainText, .json, .html, .pdf]) { result in
                switch result {
                case .success(let url):
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    guard url.pathExtension.lowercased() != "pdf" else {
                        errorText = "PDF extraction isn't in this prototype yet. Import a text file."
                        return
                    }
                    if let content = try? String(contentsOf: url, encoding: .utf8) {
                        composer += "\n\nAttached file \(url.lastPathComponent):\n" + String(content.prefix(18000))
                    } else { errorText = "Unable to read text file." }
                case .failure(let error): errorText = error.localizedDescription
                }
            }
            .alert("Approve agent tool?", isPresented: $toolAlert, presenting: pendingTool) { proposal in
                Button("Allow") {
                    Task {
                        do {
                            let result = try await ToolRouter.execute(proposal, store: store)
                            store.save(ToolAudit(tool: proposal.name, detail: proposal.title ?? proposal.text ?? "",
                                                 approved: true, result: result))
                            if let thread = current { _ = store.append(role: "assistant", text: result, to: thread) }
                        } catch {
                            store.save(ToolAudit(tool: proposal.name, detail: proposal.title ?? "",
                                                 approved: true, result: error.localizedDescription))
                            errorText = error.localizedDescription
                        }
                        pendingTool = nil
                    }
                }
                Button("Deny", role: .cancel) {
                    store.save(ToolAudit(tool: proposal.name, detail: proposal.title ?? "",
                                         approved: false, result: "User denied"))
                    pendingTool = nil
                }
            } message: { proposal in
                Text("Allow \(proposal.name)\n\(proposal.title ?? proposal.text ?? proposal.details ?? "")\n\(proposal.at ?? "")")
            }
            .onAppear { ensureChat() }
            .onChange(of: store.database.ready) { _ in ensureChat() }
        }
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Button { importFile = true } label: { Image(systemName: "paperclip").font(.title3) }
                    .accessibilityLabel("Attach text file")
                    .disabled(isLoading)
                TextEditor(text: $composer)
                    .frame(minHeight: 42, maxHeight: 116)
                    .padding(4)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Message")
                Button {
                    if isLoading {
                        task?.cancel()
                    } else { send() }
                } label: {
                    Image(systemName: isLoading ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!isLoading && composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                if let chat = current, let provider = store.provider(for: chat) {
                    Text("\(provider.name) · \(provider.model)")
                } else {
                    Text("Set up an API provider in Settings")
                }
                Spacer()
                if let chat = current {
                    Menu {
                        ForEach(store.agents) { agent in
                            Button(agent.name) {
                                var updated = chat
                                updated.agentID = agent.id
                                store.save(updated)
                            }
                        }
                    } label: { Label(store.agent(for: chat).name, systemImage: "chevron.down") }
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func ensureChat() {
        guard store.database.ready else { return }
        if let chatID, store.chats.contains(where: { $0.id == chatID }) { return }
        chatID = store.chats.first(where: { !$0.archived })?.id ?? store.createChat().id
    }

    private func newChat() {
        guard store.database.ready else { return }
        chatID = store.createChat().id
        composer = ""
        errorText = ""
    }

    private func send() {
        guard let thread = current, !isLoading else { return }
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let profile = store.provider(for: thread) else {
            errorText = "Add an API provider in Settings first."
            return
        }
        composer = ""
        streaming = ""
        errorText = ""
        let message = store.append(role: "user", text: text, to: thread)
        for candidate in MemoryEngine.candidates(from: text, messageID: message.id, chatID: thread.id) {
            if !MemoryEngine.containsSimilar(candidate, in: store.memories) { store.save(candidate) }
        }
        let context = MemoryEngine.context(chat: thread, allMessages: store.messages,
                                           agent: store.agent(for: thread),
                                           profile: profile, memories: store.memories, summaries: store.summaries)
        store.lastDiagnostic = context.diagnostic
        var requestMessages = context.messages
        if !requestMessages.isEmpty {
            requestMessages[0].content += "\n" + MemoryEngine.agentToolInstructions
        }
        isLoading = true
        task = Task {
            do {
                let raw = try await LLMService.request(profile: profile, messages: requestMessages) { part in
                    streaming += part
                }
                let tool = ToolRouter.extract(from: raw)
                let wantApp = raw.contains("[[BUILD_HTMLAPP]]")
                let cleaned = ToolRouter.cleanedResponse(raw).replacingOccurrences(of: "[[BUILD_HTMLAPP]]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                _ = store.append(role: "assistant", text: cleaned, to: thread)
                if let tool { pendingTool = tool; toolAlert = true }
                if wantApp { buildPrompt = BuildPrompt(text: text) }
                if autoSummaryEnabled { await summarizeIfNeeded(thread: thread, profile: profile) }
            } catch is CancellationError {
                if !streaming.isEmpty { _ = store.append(role: "assistant", text: streaming + "\n[Interrupted]", to: thread) }
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
            streaming = ""
        }
    }

    private func summarizeIfNeeded(thread: ChatThread, profile: ProviderProfile) async {
        let messages = store.messages(in: thread.id)
        let old = store.summaries.filter { $0.chatID == thread.id }
        guard MemoryEngine.shouldSummarize(messages, existing: old) else { return }
        let input = MemoryEngine.summaryPrompt(for: messages)
        if let text = try? await LLMService.request(profile: profile, messages: [
            LLMMessage(role: "system", content: "Summarize accurately. Never infer secrets or sensitive traits."),
            LLMMessage(role: "user", content: input)
        ]) { _ in } {
            store.save(SessionSummary(chatID: thread.id, throughMessageID: messages.last?.id,
                                      coveredCount: messages.count, text: String(text.prefix(4500))))
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "You" : "ASSistant")
                    .font(.caption2).foregroundColor(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(isUser ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14))
            .contextMenu { Button("Copy") { UIPasteboard.general.string = message.content } }
            if !isUser { Spacer(minLength: 24) }
        }
    }
}

private struct ChatPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: UUID?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.chats.filter { chat in
                    query.isEmpty || chat.title.localizedCaseInsensitiveContains(query) ||
                    store.messages(in: chat.id).contains(where: { $0.content.localizedCaseInsensitiveContains(query) })
                }) { chat in
                    Button {
                        selected = chat.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(chat.title).font(.headline)
                            Text(chat.updatedAt, style: .date).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            for msg in store.messages(in: chat.id) { store.delete(msg.id, kind: "message") }
                            store.delete(chat.id, kind: "chat")
                        } label: { Text("Delete") }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Conversations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
