import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Vision
import PDFKit
import UIKit

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
    @AppStorage("autoSummaryEnabled") private var autoSummaryEnabled = true
    @StateObject private var speech = SpeechRecorder()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var suggestedAppPrompt: String?
    @State private var showAppDecision = false
    @State private var autoBuildStatus = ""
    @State private var appBuildTask: Task<Void, Never>?
    @StateObject private var browser = BrowserSession()
    @StateObject private var whisper = WhisperRecorder()
    @AppStorage("dictationEngine") private var dictationEngine = "whisper"
    @State private var showCallMode = false
    @State private var agentStatus = ""
    @State private var editingMessage: ChatMessage?

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
                                    MessageBubble(message: message,
                                                  onEdit: message.role == "user" ? { editingMessage = message } : nil,
                                                  onRegenerate: message.role == "assistant" ? { regenerate(message) } : nil)
                                        .id(message.id)
                                }
                                if isLoading {
                                    HStack(alignment: .top) {
                                        Text(streaming.isEmpty ? (agentStatus.isEmpty ? "Thinking…" : agentStatus) : streaming)
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
                    if !autoBuildStatus.isEmpty {
                        HStack {
                            Text(autoBuildStatus).font(.caption)
                            Spacer()
                            if appBuildTask != nil {
                                Button("Cancel") { appBuildTask?.cancel() }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
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
            .overlay(alignment: .bottomTrailing) {
                BrowserDock(session: browser)
                    .padding(.bottom, 100)
            }
            .navigationTitle(current?.title ?? "ASSistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "line.3.horizontal") }
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showCallMode = true
                    } label: {
                        Image(systemName: "phone.arrow.up.right.fill")
                    }
                    .accessibilityLabel("Start voice call mode")
                    Menu {
                        Button("Open live browser") {
                            browser.visible = true
                            browser.expanded = true
                            browser.userControl = true
                            if browser.currentURL.isEmpty {
                                Task {
                                    browser.userControl = false
                                    _ = try? await browser.navigate("https://www.google.com")
                                    browser.userControl = true
                                }
                            }
                        }
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
            .sheet(isPresented: $showCallMode) {
                if let id = chatID {
                    CallModeView(chatID: id) { transcript in
                        sendText(transcript)
                    }
                    .environmentObject(store)
                }
            }
            .sheet(item: $editingMessage) { message in
                MessageEditSheet(original: message.content) { revision in
                    reviseUserMessage(message, to: revision)
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
                    if url.pathExtension.lowercased() == "pdf" {
                        if let pdf = PDFDocument(url: url), let content = pdf.string, !content.isEmpty {
                            composer += "\n\nPDF text from \(url.lastPathComponent):\n" + String(content.prefix(18000))
                        } else { errorText = "This PDF has no extractable text." }
                    } else if let content = try? String(contentsOf: url, encoding: .utf8) {
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
            .confirmationDialog("Build an HTMLApp?", isPresented: $showAppDecision, titleVisibility: .visible) {
                Button("Generate, publish and open HTMLApp") {
                    if let prompt = suggestedAppPrompt { beginAutomaticHTMLApp(prompt) }
                }
                Button("Review HTML before publishing") {
                    if let prompt = suggestedAppPrompt { buildPrompt = BuildPrompt(text: prompt) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("ASSistant will use the HTMLApp skill, generate working single-file HTML, publish it at a shareable HTTPS link, then open HTMLApp's import screen. Anyone with the link can read its HTML source.")
            }
            .onChange(of: selectedPhoto) { photo in
                guard let photo else { return }
                Task {
                    do {
                        guard let bytes = try await photo.loadTransferable(type: Data.self) else {
                            errorText = "Could not load selected photo."
                            return
                        }
                        let extracted = try await Self.extractPhotoText(bytes)
                        if extracted.isEmpty { errorText = "No readable text found in the photo." }
                        else { composer += "\n\nText recognized from photo:\n" + String(extracted.prefix(16000)) }
                    } catch { errorText = error.localizedDescription }
                }
            }
            .onChange(of: speech.transcript) { transcript in
                if !transcript.isEmpty { composer = transcript }
            }
            .onDisappear {
                speech.stop()
                if !showCallMode { whisper.cancel() }
            }
            .onAppear { ensureChat() }
            .onChange(of: store.database.ready) { _ in ensureChat() }
        }
    }

    private var composerArea: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Button { importFile = true } label: { Image(systemName: "paperclip").font(.title3) }
                    .accessibilityLabel("Attach text or PDF file")
                    .disabled(isLoading)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo").font(.title3)
                }
                .accessibilityLabel("Read text from photo")
                .disabled(isLoading)
                Button {
                    if dictationEngine == "apple" {
                        if speech.recording { speech.stop() }
                        else {
                            Task {
                                do { try await speech.start() }
                                catch { errorText = error.localizedDescription }
                            }
                        }
                    } else if whisper.isRecording {
                        Task {
                            do {
                                let transcript = try await whisper.stopAndTranscribe(
                                    profile: current.flatMap { store.provider(for: $0) }
                                )
                                composer += (composer.isEmpty ? "" : " ") + transcript
                            } catch { errorText = error.localizedDescription }
                        }
                    } else {
                        Task {
                            do { try await whisper.start() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                } label: {
                    Image(systemName: (whisper.isRecording || speech.recording) ? "mic.fill" : "mic")
                        .foregroundColor((whisper.isRecording || speech.recording) ? .red : .blue)
                        .font(.title3)
                        .symbolEffect(.pulse, options: .repeating,
                                      isActive: whisper.isRecording || speech.recording)
                }
                .accessibilityLabel(whisper.isRecording || speech.recording ? "Stop and transcribe" : "Start dictation")
                .disabled(isLoading || whisper.isTranscribing)
                if whisper.isTranscribing { ProgressView().controlSize(.small) }
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

    private static func extractPhotoText(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data)?.cgImage else { throw DeviceToolError.unavailable }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    private func beginAutomaticHTMLApp(_ request: String) {
        guard appBuildTask == nil else { return }
        guard let thread = current, let provider = store.provider(for: thread) else {
            errorText = "Configure an API provider before creating an app."
            return
        }
        appBuildTask = Task {
            var localApp: GeneratedApp?
            defer {
                appBuildTask = nil
                autoBuildStatus = ""
            }
            do {
                autoBuildStatus = "Generating HTML from the HTMLApp skill…"
                let app = try await HTMLAppBuilder.generate(request: request, profile: provider)
                try Task.checkCancellation()
                localApp = app
                store.save(app)
                autoBuildStatus = "Uploading the HTML file…"
                let endpoint = UserDefaults.standard.string(forKey: "publisherEndpoint") ?? ""
                let raw: String
                if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    raw = try await HTMLPublisher.uploadToGist(app)
                } else {
                    raw = try await HTMLPublisher.uploadToCustomEndpoint(
                        app, endpoint: endpoint, bearer: KeychainStore.get("publisher.customToken")
                    )
                }
                try Task.checkCancellation()
                var published = app
                published.sourceURL = raw
                store.save(published)
                autoBuildStatus = "Opening HTMLApp import…"
                try await HTMLAppBuilder.openHTMLApp(raw)
                _ = store.append(role: "assistant", text:
                    "Created \(published.title), hosted its HTML and opened the HTMLApp import screen. Choose Save App in HTMLApp to install it.", to: thread)
            } catch is CancellationError {
                errorText = "HTMLApp creation was cancelled. Any previously published file remains accessible."
            } catch {
                errorText = "HTMLApp creation: \(error.localizedDescription)"
                if let localApp {
                    buildPrompt = BuildPrompt(text: localApp.prompt)
                }
            }
        }
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
        let value = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        composer = ""
        sendText(value)
    }

    private func sendText(_ text: String) {
        guard let thread = current, !isLoading else { return }
        guard store.provider(for: thread) != nil else {
            errorText = "Add an API provider in Settings first."
            return
        }
        errorText = ""
        let message = store.append(role: "user", text: text, to: thread)
        for candidate in MemoryEngine.candidates(from: text, messageID: message.id, chatID: thread.id) {
            if !MemoryEngine.containsSimilar(candidate, in: store.memories) {
                store.save(candidate)
            }
        }
        generateAnswer(thread: thread, userPrompt: text)
    }

    private func regenerate(_ message: ChatMessage) {
        guard !isLoading, let thread = current else { return }
        let visible = currentMessages
        guard let index = visible.firstIndex(where: { $0.id == message.id }) else { return }
        for old in visible[index...] where old.role == "assistant" {
            var previous = old
            previous.status = "superseded"
            store.save(previous)
        }
        guard let latestUser = store.messages(in: thread.id).last(where: { $0.role == "user" }) else {
            return
        }
        generateAnswer(thread: thread, userPrompt: latestUser.content)
    }

    private func reviseUserMessage(_ message: ChatMessage, to revision: String) {
        guard !isLoading, let thread = current else { return }
        let text = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let all = currentMessages
        guard let index = all.firstIndex(where: { $0.id == message.id }) else { return }
        // Keep original turns as recoverable revisions, never silently erase them.
        for old in all[index...] {
            var previous = old
            previous.status = "superseded"
            store.save(previous)
        }
        sendText(text)
    }

    private func generateAnswer(thread: ChatThread, userPrompt: String) {
        guard !isLoading, let profile = store.provider(for: thread) else { return }
        streaming = ""
        agentStatus = "Preparing context…"
        errorText = ""
        let context = MemoryEngine.context(chat: thread, allMessages: store.messages,
                                           agent: store.agent(for: thread), profile: profile,
                                           memories: store.memories, summaries: store.summaries)
        store.lastDiagnostic = context.diagnostic
        isLoading = true
        task = Task {
            do {
                let outcome = try await AgentEngine.run(
                    profile: profile, input: context.messages,
                    prompt: userPrompt,
                    enableWeb: store.agent(for: thread).allowedTools.contains("web"),
                    browser: browser,
                    onStatus: { status in
                        agentStatus = status
                        streaming = ""
                    },
                    onDelta: { piece in
                        if streaming.count < 24000 { streaming += piece }
                    }
                )
                _ = store.append(role: "assistant", text: outcome.text, to: thread)
                if let tool = outcome.pendingTool {
                    let category: String
                    switch tool.name {
                    case "create_reminder": category = "reminder"
                    case "create_calendar_event": category = "calendar"
                    case "schedule_notification": category = "notification"
                    case "get_location": category = "location"
                    case "count_contacts": category = "contacts"
                    case "copy_text": category = "clipboard"
                    case "speak_text": category = "speak"
                    default: category = "task"
                    }
                    if category == "task" || store.agent(for: thread).allowedTools.contains(category) {
                        pendingTool = tool
                        toolAlert = true
                    } else {
                        _ = store.append(role: "assistant", text:
                            "This agent is not allowed to use the \(category) tool.", to: thread)
                    }
                }
                if outcome.wantsHTMLApp {
                    suggestedAppPrompt = userPrompt
                    showAppDecision = true
                }
                if autoSummaryEnabled { await summarizeIfNeeded(thread: thread, profile: profile) }
            } catch is CancellationError {
                if !streaming.isEmpty, !streaming.contains("<assistant_tool>") {
                    _ = store.append(role: "assistant", text:
                        streaming + "\n[Interrupted]", to: thread)
                }
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
            agentStatus = ""
            streaming = ""
        }
    }

    private func summarizeIfNeeded(thread: ChatThread, profile: ProviderProfile) async {
        let messages = store.messages(in: thread.id)
        let old = store.summaries.filter { $0.chatID == thread.id }
        guard MemoryEngine.shouldSummarize(messages, existing: old) else { return }
        let previous = old.max(by: { $0.coveredCount < $1.coveredCount })
        let input = MemoryEngine.summaryPrompt(for: messages, previous: previous)
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
    let onEdit: (() -> Void)?
    let onRegenerate: (() -> Void)?
    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 26) }
            if !isUser {
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(.cyan)
                    .padding(8)
                    .background(Color.cyan.opacity(0.12), in: Circle())
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(isUser ? "You" : "ASSistant")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(isUser ? Color.white.opacity(0.85) : Color.secondary)
                    Spacer()
                    Text(message.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(isUser ? Color.white.opacity(0.65) : Color.secondary)
                }
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .tint(isUser ? .white : .blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .background(
                isUser
                  ? AnyShapeStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                  : AnyShapeStyle(Color.secondary.opacity(0.11)),
                in: RoundedRectangle(cornerRadius: 17)
            )
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .contextMenu {
                Button("Copy") { UIPasteboard.general.string = message.content }
                if let onEdit { Button("Edit message", systemImage: "pencil", action: onEdit) }
                if let onRegenerate { Button("Regenerate answer", systemImage: "arrow.clockwise", action: onRegenerate) }
            }
            if !isUser { Spacer(minLength: 18) }
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
    }
}

private struct MessageEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var revision: String
    let onSave: (String) -> Void

    init(original: String, onSave: @escaping (String) -> Void) {
        _revision = State(initialValue: original)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $revision)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
                Text("Editing this turn starts a new response and preserves the previous turns as history.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            .navigationTitle("Edit message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & resend") {
                        onSave(revision)
                        dismiss()
                    }
                    .disabled(revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
