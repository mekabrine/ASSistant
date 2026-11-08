import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Vision
import PDFKit
import UIKit
import MessageUI

private struct BuildPrompt: Identifiable {
    let id = UUID()
    var text: String
}

@MainActor
struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var chatID: UUID?
    @ObservedObject var browser: BrowserWorkspace
    var toggleSidebar: (() -> Void)?

    init(chatID: Binding<UUID?>, browser: BrowserWorkspace,
         toggleSidebar: (() -> Void)? = nil) {
        self._chatID = chatID
        self.browser = browser
        self.toggleSidebar = toggleSidebar
    }
    @State private var composer = ""
    @State private var streaming = ""
    @State private var errorText = ""
    @State private var isLoading = false
    @State private var showChats = false
    @State private var importFile = false
    @State private var attachmentsExpanded = false
    @State private var cameraOpen = false
    @State private var buildPrompt: BuildPrompt?
    @State private var pendingTool: ProposedTool?
    @State private var toolAlert = false
    @State private var task: Task<Void, Never>?
    @State private var activeRequestID = UUID()
    @AppStorage("autoSummaryEnabled") private var autoSummaryEnabled = true
    @StateObject private var speech = SpeechRecorder()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var suggestedAppPrompt: String?
    @State private var showAppDecision = false
    @State private var autoBuildStatus = ""
    @State private var appBuildTask: Task<Void, Never>?
    @StateObject private var whisper = WhisperRecorder()
    @AppStorage("dictationEngine") private var dictationEngine = "whisper"
    @State private var showCallMode = false
    @State private var agentStatus = ""
    @State private var editingMessage: ChatMessage?
    @State private var showActivity = false
    @State private var editingInlineApp: GeneratedApp?
    @State private var smsDraft: SMSDraft?
    @State private var smsProposal: ProposedTool?

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
                                if currentMessages.isEmpty {
                                    welcomeCard
                                        .padding(.top, 34)
                                        .padding(.bottom, 18)
                                }
                                ForEach(currentMessages) { message in
                                    MessageBubble(message: message,
                                                  onEdit: message.role == "user" ? { editingMessage = message } : nil,
                                                  onRegenerate: message.role == "assistant" ? { regenerate(message) } : nil,
                                                  onChoice: message.role == "assistant" ? { selection in sendText(selection) } : nil)
                                        .id(message.id)
                                }
                                ForEach(store.apps.filter { $0.chatID == current.id }) { app in
                                    ChatHTMLAppCard(app: app,
                                        onEdit: { editingInlineApp = app },
                                        onPublish: { publishInlineApp(app) })
                                        .id(app.id)
                                }
                                if isLoading {
                                    HStack(alignment: .top) {
                                        TypingPulse()
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
            .background(AmbientBackground())
            .overlay(alignment: .bottomTrailing) {
                BrowserDock(workspace: browser)
                    .padding(.bottom, 100)
            }
            .navigationTitle(current?.title ?? "ASSistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        toggleSidebar?()
                    } label: { Image(systemName: "sidebar.left") }
                    .accessibilityLabel("Toggle chat sidebar")
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showActivity = true
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .accessibilityLabel("Agent activity timeline")
                    Button {
                        showCallMode = true
                    } label: {
                        Image(systemName: "phone.arrow.up.right.fill")
                    }
                    .accessibilityLabel("Start voice call mode")
                    Menu {
                        Button("Open live browser") {
                            browser.open()
                            if browser.active.currentURL.isEmpty {
                                Task {
                                    _ = try? await browser.active.navigate("https://www.google.com")
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
            .fullScreenCover(isPresented: $browser.fullScreen) {
                BrowserFullScreenView(workspace: browser)
            }
            .sheet(isPresented: $showActivity) {
                AgentActivityView().environmentObject(store)
            }
            .sheet(item: $smsDraft) { draft in
                MessageComposeSheet(draft: draft) { outcome in
                    if let proposal = smsProposal {
                        store.save(ToolAudit(tool: proposal.name, detail: draft.recipient,
                                             approved: true, result: outcome))
                        if let thread = current {
                            _ = store.append(role: "assistant", text: outcome, to: thread)
                        }
                    }
                    smsProposal = nil
                    smsDraft = nil
                }
            }
            .sheet(isPresented: $showCallMode) {
                if let id = chatID {
                    CallModeView(chatID: id, agentProgress: $agentStatus) { transcript in
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
            .sheet(item: $editingInlineApp) { app in
                AppBuilderScreen(initialPrompt: app.prompt, existing: app)
                    .environmentObject(store)
            }
            .sheet(isPresented: $cameraOpen) {
                CameraCaptureView(onCapture: { bytes in
                    cameraOpen = false
                    Task { await addPhotoText(bytes, label: "Camera photo") }
                }, onCancel: { cameraOpen = false })
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
                            if proposal.name == "compose_sms" {
                                guard MFMessageComposeViewController.canSendText() else {
                                    throw NativeActionError.messagesUnavailable
                                }
                                let number = try await NativeActions.resolvePhone(proposal.recipient ?? "")
                                let body = proposal.text ?? ""
                                guard !body.isEmpty, body.count < 6000 else {
                                    throw DeviceToolError.missingInput
                                }
                                smsProposal = proposal
                                smsDraft = SMSDraft(recipient: number, message: body)
                                pendingTool = nil
                                return
                            }
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
                Text("Approve: \(proposal.name.replacingOccurrences(of: "_", with: " "))\nRecipient: \(proposal.recipient ?? "not applicable")\nSubject/Title: \(proposal.subject ?? proposal.title ?? "")\n\(String((proposal.text ?? proposal.details ?? "").prefix(600)))\n\(proposal.at ?? "")")
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
                        await addPhotoText(bytes, label: "Selected photo")
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
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        attachmentsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .rotationEffect(.degrees(attachmentsExpanded ? 45 : 0))
                }
                .accessibilityLabel("Expand attachments")
                if attachmentsExpanded {
                    Button {
                        attachmentsExpanded = false
                        importFile = true
                    } label: { Image(systemName: "doc").font(.title3) }
                    .accessibilityLabel("Attach file")
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo").font(.title3)
                    }
                    .accessibilityLabel("Choose photo")
                    Button {
                        attachmentsExpanded = false
                        cameraOpen = true
                    } label: { Image(systemName: "camera.fill").font(.title3) }
                    .accessibilityLabel("Take photo")
                }
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
                        .scaleEffect((whisper.isRecording || speech.recording) ? 1.12 : 1.0)
                        .animation(.easeInOut(duration: 0.25), value: whisper.isRecording || speech.recording)
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
                    if isLoading && composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        task?.cancel()
                        browser.stopAll()
                    } else { send() }
                } label: {
                    Image(systemName: isLoading && composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "stop.circle.fill" : "arrow.up.circle.fill")
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.cyan.opacity(0.14)))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private var welcomeCard: some View {
        VStack(spacing: 15) {
            AssistantOrb(size: 74)
                .frame(height: 120)
            Text("Your assistant, your models")
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
            Text("Search the live web, talk naturally, build mini-apps, and remember what matters.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 15)
            VStack(spacing: 9) {
                SoftActionButton(text: "Research something online", icon: "globe") {
                    composer = "Search the web and compare options for "
                }
                SoftActionButton(text: "Make me a mini app", icon: "hammer.fill") {
                    buildPrompt = BuildPrompt(text: "Make a useful mini app for ")
                }
                SoftActionButton(text: "Start a voice call", icon: "phone.fill") {
                    showCallMode = true
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.cyan.opacity(0.14)))
    }

    private func addPhotoText(_ bytes: Data, label: String) async {
        do {
            let extracted = try await Self.extractPhotoText(bytes)
            if extracted.isEmpty {
                errorText = "No readable text was found in the photo. Image-model input isn't enabled for this provider."
            } else {
                composer += "\n\n" + label + " OCR:\n" + String(extracted.prefix(16000))
            }
        } catch { errorText = error.localizedDescription }
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

    private func shouldBuildHTMLApp(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["build me an app", "make me an app", "create an app",
                "build an htmlapp", "make an htmlapp", "generate an html app",
                "build a mini app", "create a mini app", "make a mini app",
                "build me a website", "create a web app"].contains(where: lower.contains)
    }

    private func beginInlineHTMLApp(_ request: String, thread: ChatThread,
                                    profile: ProviderProfile) {
        guard appBuildTask == nil else { return }
        appBuildTask = Task {
            defer { appBuildTask = nil; autoBuildStatus = "" }
            do {
                autoBuildStatus = "Building your interactive HTMLApp preview in chat…"
                var app = try await HTMLAppBuilder.generate(request: request, profile: profile)
                try Task.checkCancellation()
                app.chatID = thread.id
                store.save(app)
                _ = store.append(role: "assistant", text:
                    "I built **\(app.title)** below. You can use its preview, edit the HTML, or explicitly publish and import it into HTMLApp.", to: thread)
            } catch is CancellationError {
                errorText = "HTMLApp draft generation was cancelled."
            } catch {
                errorText = "HTMLApp generation: " + error.localizedDescription
            }
        }
    }

    private func publishInlineApp(_ app: GeneratedApp) {
        appBuildTask?.cancel()
        appBuildTask = Task {
            defer { appBuildTask = nil; autoBuildStatus = "" }
            do {
                autoBuildStatus = "Preparing HTMLApp import…"
                let url: String
                if let existing = app.sourceURL { url = existing }
                else {
                    url = try await HTMLPublisher.publish(app)
                    var saved = app
                    saved.sourceURL = url
                    store.save(saved)
                }
                try await HTMLAppBuilder.openHTMLApp(url)
            } catch { errorText = "HTMLApp publish/import: " + error.localizedDescription }
        }
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
                let raw = try await HTMLPublisher.publish(app)
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
        guard let thread = current else { return }
        if isLoading {
            task?.cancel()
            activeRequestID = UUID()
            browser.resumeOnNextMessage()
            isLoading = false
            streaming = ""
        }
        guard store.provider(for: thread) != nil else {
            errorText = "Add an API provider in Settings first."
            return
        }
        errorText = ""
        browser.resumeOnNextMessage()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let message = store.append(role: "user", text: text, to: thread)
        if thread.title == "New Chat" {
            var renamed = thread
            renamed.title = ChatTitleService.fallback(text)
            store.save(renamed)
        }
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
        guard let index = visible.firstIndex(where: { $0.id == message.id }),
              let previousUser = visible[..<index].last(where: { $0.role == "user" }) else { return }
        // Regenerating an older answer branches from its preceding user turn.
        // Later messages stay saved as superseded revisions, not deleted.
        for old in visible[index...] {
            var previous = old
            previous.status = "superseded"
            store.save(previous)
        }
        invalidateSummaries(for: thread.id)
        generateAnswer(thread: thread, userPrompt: previousUser.content)
    }

    private func reviseUserMessage(_ message: ChatMessage, to revision: String) {
        guard !isLoading, let thread = current else { return }
        let text = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let all = currentMessages
        guard let index = all.firstIndex(where: { $0.id == message.id }) else { return }
        // Keep original turns as recoverable revisions, never silently erase them.
        let invalidatedIDs = Set(all[index...].map(\.id))
        for old in all[index...] {
            var previous = old
            previous.status = "superseded"
            store.save(previous)
        }
        // Facts extracted from a retracted user message must not survive
        // the correction or leak into later LLM calls.
        for fact in store.memories where
            fact.sourceMessageID.map({ invalidatedIDs.contains($0) }) == true && !fact.pinned {
            store.delete(fact.id, kind: "memory")
        }
        invalidateSummaries(for: thread.id)
        sendText(text)
    }

    private func invalidateSummaries(for chatID: UUID) {
        for summary in store.summaries where summary.chatID == chatID {
            store.delete(summary.id, kind: "summary")
        }
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
        let requestID = UUID()
        activeRequestID = requestID
        task = Task {
            do {
                let outcome = try await AgentEngine.run(
                    profile: profile, input: context.messages,
                    prompt: userPrompt,
                    enableWeb: store.agent(for: thread).allowedTools.contains("web"),
                    allowedToolCategories: store.agent(for: thread).allowedTools,
                    chat: thread, agent: store.agent(for: thread), memories: store.memories,
                    browser: browser,
                    onStatus: { status in
                        guard activeRequestID == requestID else { return }
                        agentStatus = status
                        streaming = ""
                    },
                    onDelta: { piece in
                        guard activeRequestID == requestID else { return }
                        if streaming.count < 24000 { streaming += piece }
                    },
                    onBrowserStep: { name, observation in
                        guard activeRequestID == requestID else { return }
                        store.save(ToolAudit(tool: name, detail: userPrompt,
                                             approved: true, result: observation))
                    }
                )
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                _ = store.append(role: "assistant", text: outcome.text, to: thread)
                let count = store.messages(in: thread.id).count
                if ChatTitleService.shouldRename(count: count) {
                    Task { await updateChatTitle(threadID: thread.id, model: profile) }
                }
                if let tool = outcome.pendingTool {
                    let category = ToolRouter.category(for: tool.name)
                    if category == "task" || store.agent(for: thread).allowedTools.contains(category) {
                        pendingTool = tool
                        toolAlert = true
                    } else {
                        _ = store.append(role: "assistant", text:
                            "The \(category) tool is disabled for this agent. Enable it in Settings → Agents.", to: thread)
                    }
                }
                if shouldBuildHTMLApp(userPrompt) {
                    beginInlineHTMLApp(userPrompt, thread: thread, profile: profile)
                } else if outcome.wantsHTMLApp {
                    suggestedAppPrompt = userPrompt
                    showAppDecision = true
                }
                if autoSummaryEnabled { await summarizeIfNeeded(thread: thread, profile: profile) }
            } catch is CancellationError {
                if activeRequestID == requestID,
                   !streaming.isEmpty, !streaming.contains("<assistant_tool>") {
                    _ = store.append(role: "assistant", text:
                        streaming + "\n[Interrupted]", to: thread)
                }
            } catch {
                if activeRequestID == requestID { errorText = error.localizedDescription }
            }
            if !Task.isCancelled && activeRequestID == requestID {
                isLoading = false
                agentStatus = ""
                streaming = ""
            }
        }
    }

    private func updateChatTitle(threadID: UUID, model: ProviderProfile) async {
        guard let thread = store.chats.first(where: { $0.id == threadID }) else { return }
        if let title = await ChatTitleService.generate(
            chat: thread, messages: store.messages(in: threadID),
            availableProviders: store.providers, fallbackProvider: model
        ), var updated = store.chats.first(where: { $0.id == threadID }) {
            updated.title = title
            store.save(updated)
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
    let onChoice: ((String) -> Void)?
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
                RichMessageView(content: message.content, onChoice: onChoice)
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
                if let onEdit { Button(action: onEdit) { Label("Edit message", systemImage: "pencil") } }
                if let onRegenerate { Button(action: onRegenerate) { Label("Regenerate answer", systemImage: "arrow.clockwise") } }
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

private struct ChatGroup: Identifiable {
    let id: String
    let chats: [ChatThread]
}

private struct ChatPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: UUID?
    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: ChatThread?

    private var filtered: [ChatThread] {
        store.chats.filter { chat in
            chat.archived == showArchived &&
            (query.isEmpty || chat.title.localizedCaseInsensitiveContains(query) ||
             store.messages(in: chat.id).contains(where: {
                 $0.content.localizedCaseInsensitiveContains(query)
             }))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var groups: [ChatGroup] {
        let calendar = Calendar.current
        let today = filtered.filter { calendar.isDateInToday($0.updatedAt) }
        let yesterday = filtered.filter { calendar.isDateInYesterday($0.updatedAt) }
        let week = filtered.filter {
            !calendar.isDateInToday($0.updatedAt) && !calendar.isDateInYesterday($0.updatedAt) &&
            $0.updatedAt > Date().addingTimeInterval(-7 * 86400)
        }
        let older = filtered.filter { $0.updatedAt <= Date().addingTimeInterval(-7 * 86400) }
        return [ChatGroup(id: "Today", chats: today),
                ChatGroup(id: "Yesterday", chats: yesterday),
                ChatGroup(id: "Previous 7 days", chats: week),
                ChatGroup(id: "Older", chats: older)]
            .filter { !$0.chats.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selected = store.createChat().id
                        dismiss()
                    } label: {
                        Label("New conversation", systemImage: "square.and.pencil")
                            .fontWeight(.semibold)
                    }
                    Toggle("Show archived conversations", isOn: $showArchived)
                }
                ForEach(groups) { group in
                    Section(group.id) {
                        ForEach(group.chats) { chat in
                            Button {
                                selected = chat.id
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: selected == chat.id
                                          ? "bubble.left.and.bubble.right.fill"
                                          : "bubble.left.and.bubble.right")
                                        .foregroundStyle(selected == chat.id ? .cyan : .secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(chat.title)
                                            .font(.headline).lineLimit(1)
                                        if let last = store.messages(in: chat.id).last {
                                            Text(last.content.replacingOccurrences(of: "\n", with: " "))
                                                .font(.caption).foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        HStack {
                                            Text(chat.updatedAt, style: .relative)
                                            Text("·")
                                            Text("\(store.messages(in: chat.id).count) messages")
                                        }
                                        .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if selected == chat.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan) }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    for item in store.messages(in: chat.id) {
                                        store.delete(item.id, kind: "message")
                                    }
                                    store.delete(chat.id, kind: "chat")
                                } label: { Label("Delete", systemImage: "trash") }
                                Button {
                                    var archived = chat
                                    archived.archived.toggle()
                                    store.save(archived)
                                } label: {
                                    Label(chat.archived ? "Unarchive" : "Archive", systemImage: "archivebox")
                                }.tint(.indigo)
                            }
                            .contextMenu {
                                Button {
                                    renaming = chat
                                } label: { Label("Rename", systemImage: "pencil") }
                            }
                        }
                    }
                }
                if filtered.isEmpty {
                    Section {
                        Text("No matching conversations")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search titles and chat messages")
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Conversations")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $renaming) { chat in
                ChatRenameSheet(chat: chat) { title in
                    var updated = chat
                    updated.title = title
                    store.save(updated)
                }
            }
        }
    }
}

private struct ChatRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: ChatThread
    let onSave: (String) -> Void
    @State private var title: String

    init(chat: ChatThread, onSave: @escaping (String) -> Void) {
        self.chat = chat
        self.onSave = onSave
        _title = State(initialValue: chat.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Conversation name", text: $title)
            }
            .navigationTitle("Rename conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty { onSave(String(value.prefix(80))); dismiss() }
                    }
                }
            }
        }
    }
}
