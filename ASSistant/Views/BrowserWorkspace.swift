import Foundation
import SwiftUI
import WebKit
import Combine

/// Only browser tabs belong to a chat. Website cookies remain in the app's
/// persistent WebKit store, so users can sign in without sharing Safari cookies.
@MainActor
final class BrowserWorkspace: ObservableObject {
    static let shared = BrowserWorkspace()

    private struct LiveChat {
        var tabs: [BrowserSession]
        var selectedID: UUID?
        var dockX: Double
        var dockY: Double
    }

    @Published private(set) var sessions: [BrowserSession] = [BrowserSession()]
    @Published var selectedID: UUID?
    @Published private(set) var currentChatID: UUID?
    @Published var fullScreen = false
    @Published var awaitingHuman = false
    @Published var handoffBrowserID: UUID?
    @Published var dockX = 0.72
    @Published var dockY = 0.61

    private var openChats: [UUID: LiveChat] = [:]
    private var observers: [UUID: AnyCancellable] = [:]
    private var tabChat: [UUID: UUID] = [:]
    private var inactiveOrder: [UUID] = []
    private var delayedSave: [UUID: Task<Void, Never>] = [:]

    init() {
        selectedID = sessions.first?.id
    }

    var active: BrowserSession {
        sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
    }

    var anyVisible: Bool { sessions.contains(where: { $0.visible }) }

    /// Called whenever the actual selected chat changes, never when the
    /// mobile sidebar merely opens. Existing live tabs remain attached to
    /// their conversation, and disk snapshots survive process termination.
    func activateChat(_ chatID: UUID?) {
        guard let chatID, currentChatID != chatID else { return }

        if let previous = currentChatID {
            persist(previous)
            openChats[previous] = LiveChat(tabs: sessions,
                                           selectedID: selectedID,
                                           dockX: dockX, dockY: dockY)
            inactiveOrder.removeAll { $0 == previous }
            inactiveOrder.append(previous)
        } else {
            for tab in sessions { tab.close() }
        }

        currentChatID = chatID
        inactiveOrder.removeAll { $0 == chatID }
        // Keep only a few inactive WKWebView sets alive. Other chats restore
        // their saved URL/scroll state when reopened, avoiding web-process bloat.
        while inactiveOrder.count > 3 {
            let oldChat = inactiveOrder.removeFirst()
            guard let old = openChats[oldChat] else { continue }
            persist(oldChat)
            for tab in old.tabs {
                tab.close()
                tab.onPageUpdated = nil
                observers[tab.id] = nil
                tabChat[tab.id] = nil
            }
            openChats[oldChat] = nil
        }
        fullScreen = false
        awaitingHuman = false
        handoffBrowserID = nil

        if let live = openChats.removeValue(forKey: chatID) {
            sessions = live.tabs
            selectedID = live.selectedID
            dockX = live.dockX
            dockY = live.dockY
        } else if let record = BrowserStateStore.load(for: chatID) {
            let restored = record.tabs.prefix(6).map { snapshot -> BrowserSession in
                let tab = BrowserSession(tabID: snapshot.id)
                tab.title = snapshot.title.isEmpty ? "Restored page" : snapshot.title
                tab.currentURL = snapshot.url
                tab.pageText = snapshot.pageExcerpt
                tab.pendingRestoredScrollY = CGFloat(max(0, snapshot.scrollY))
                tab.visible = true
                attach(tab, to: chatID)
                if let safe = BrowserStateStore.restorableURL(snapshot.url),
                   let url = URL(string: safe) {
                    tab.web.load(URLRequest(url: url))
                }
                return tab
            }
            sessions = restored.isEmpty ? [BrowserSession()] : restored
            if restored.isEmpty { attach(sessions[0], to: chatID) }
            selectedID = sessions.first(where: { $0.id == record.selectedTabID })?.id
                ?? sessions.first?.id
            dockX = record.dockX
            dockY = record.dockY
        } else {
            sessions = [BrowserSession()]
            attach(sessions[0], to: chatID)
            selectedID = sessions[0].id
            dockX = 0.72
            dockY = 0.61
        }
        // Ensure previously cached live tabs are observed only once.
        for tab in sessions where observers[tab.id] == nil { attach(tab, to: chatID) }
        scheduleSave(chatID)
    }

    private func attach(_ tab: BrowserSession, to chatID: UUID) {
        tabChat[tab.id] = chatID
        tab.onPageUpdated = { [weak self] in
            self?.scheduleSave(chatID)
        }
        observers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                self?.scheduleSave(chatID)
            }
        }
    }

    private func scheduleSave(_ chatID: UUID) {
        delayedSave[chatID]?.cancel()
        delayedSave[chatID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.persist(chatID)
        }
    }

    private func persist(_ chatID: UUID) {
        let live: LiveChat
        if chatID == currentChatID {
            live = LiveChat(tabs: sessions, selectedID: selectedID,
                            dockX: dockX, dockY: dockY)
        } else if let cached = openChats[chatID] {
            live = cached
        } else { return }

        let tabs: [SavedBrowserTab] = live.tabs.compactMap { tab in
            let safeURL = BrowserStateStore.restorableURL(
                tab.web.url?.absoluteString ?? ""
            ) ?? BrowserStateStore.restorableURL(tab.currentURL)
            guard let safe = safeURL else { return nil }
            let title = String(tab.title.prefix(180))
            let excerpt = tab.controls.contains(where: { $0.inputType == "password" })
                || tab.requiresHuman ? "" : String(tab.pageText.prefix(1000))
            return SavedBrowserTab(id: tab.id, url: safe, title: title,
                                   pageExcerpt: excerpt,
                                   scrollY: Double(max(0, tab.web.scrollView.contentOffset.y)),
                                   visitedAt: .now)
        }
        BrowserStateStore.save(SavedChatBrowsers(
            chatID: chatID, selectedTabID: live.selectedID,
            tabs: tabs, dockX: live.dockX, dockY: live.dockY, savedAt: .now
        ))
    }

    func saveNow() {
        if let id = currentChatID { persist(id) }
        for id in openChats.keys { persist(id) }
    }

    func moveDock(x: Double, y: Double) {
        dockX = min(0.9, max(0.1, x))
        dockY = min(0.86, max(0.12, y))
        if let id = currentChatID { scheduleSave(id) }
    }

    @discardableResult
    func newBrowser() -> BrowserSession {
        if sessions.count >= 6,
           let old = sessions.first(where: { $0.id != selectedID && !$0.activeAgent && !$0.orderSubmissionRequested }) {
            old.close()
            observers[old.id] = nil
            tabChat[old.id] = nil
            sessions.removeAll { $0.id == old.id }
        }
        // Never go above six active tabs if every other one is busy.
        if sessions.count >= 6 { return active }
        let tab = BrowserSession()
        tab.visible = true
        sessions.append(tab)
        if let id = currentChatID { attach(tab, to: id); scheduleSave(id) }
        selectedID = tab.id
        return tab
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        active.visible = true
        if let chatID = currentChatID { scheduleSave(chatID) }
    }

    func closeTab(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let closing = sessions.remove(at: index)
        closing.close()
        closing.onPageUpdated = nil
        observers[id] = nil
        tabChat[id] = nil
        if handoffBrowserID == id {
            handoffBrowserID = nil
            awaitingHuman = false
        }
        if sessions.isEmpty {
            let replacement = BrowserSession()
            sessions = [replacement]
            if let chatID = currentChatID { attach(replacement, to: chatID) }
        }
        if selectedID == id { selectedID = sessions.first?.id }
        if let chatID = currentChatID { persist(chatID) }
    }

    func closeCurrentChatTabs() {
        let previousIDs = sessions.map(\.id)
        for id in previousIDs { closeTab(id) }
        fullScreen = false
    }

    func open() {
        active.visible = true
        fullScreen = true
    }

    func takeBackControl() {
        if let id = handoffBrowserID,
           let tab = sessions.first(where: { $0.id == id }) {
            tab.returnControl()
            selectedID = id
        } else {
            active.returnControl()
        }
        awaitingHuman = false
        handoffBrowserID = nil
    }

    func requestHuman(_ reason: String) {
        active.requestHuman(reason)
        handoffBrowserID = active.id
        awaitingHuman = true
        fullScreen = true
    }

    func resumeOnNextMessage() {
        for tab in sessions { tab.returnControl() }
        awaitingHuman = false
        handoffBrowserID = nil
    }

    func stopAll() {
        for tab in sessions { tab.stop() }
    }

    func list() -> String {
        sessions.enumerated().map { index, tab in
            "\(index + 1). id=\(tab.id.uuidString) \(String(tab.title.prefix(70))) \(tab.currentURL)"
        }.joined(separator: "\n")
    }

    func choose(_ value: String?) throws -> BrowserSession {
        guard let value, let id = UUID(uuidString: value),
              sessions.contains(where: { $0.id == id }) else {
            throw BrowserFailure.invalidLink
        }
        select(id)
        return active
    }

    func waitForHandoff() async throws -> String {
        let target = active
        guard target.requiresHuman || target.userControl else { return "" }
        handoffBrowserID = target.id
        awaitingHuman = true
        fullScreen = true
        while target.userControl {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        awaitingHuman = false
        handoffBrowserID = nil
        selectedID = target.id
        return try await target.read()
    }

    func forgetChat(_ chatID: UUID) {
        delayedSave[chatID]?.cancel()
        delayedSave[chatID] = nil
        inactiveOrder.removeAll { $0 == chatID }
        if let old = openChats.removeValue(forKey: chatID) {
            for tab in old.tabs {
                tab.close()
                tab.onPageUpdated = nil
                observers[tab.id] = nil
                tabChat[tab.id] = nil
            }
        }
        if currentChatID == chatID {
            sessions.forEach { $0.close() }
            sessions = [BrowserSession()]
            selectedID = sessions[0].id
            currentChatID = nil
            fullScreen = false
        }
        BrowserStateStore.remove(for: chatID)
    }

    func clearBrowserLogins() async {
        for tab in sessions { tab.close() }
        for live in openChats.values { live.tabs.forEach { $0.close() } }
        observers.removeAll()
        openChats.removeAll()
        inactiveOrder.removeAll()
        tabChat.removeAll()
        for task in delayedSave.values { task.cancel() }
        delayedSave.removeAll()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { continuation.resume() }
        }
        sessions = [BrowserSession()]
        if let chatID = currentChatID { attach(sessions[0], to: chatID) }
        selectedID = sessions[0].id
        awaitingHuman = false
        handoffBrowserID = nil
        fullScreen = false
        saveNow()
    }
}

@MainActor
struct BrowserDock: View {
    @ObservedObject var workspace: BrowserWorkspace
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            if workspace.anyVisible && !workspace.fullScreen {
                let width = geometry.size.width
                let height = geometry.size.height
                let minX = min(width / 2, 136.0)
                let minY = min(height / 2, 88.0)
                let maxX = max(minX, width - minX)
                let maxY = max(minY, height - 235.0)
                let centerX = clamp(CGFloat(workspace.dockX) * width + drag.width,
                                    minX, maxX)
                let centerY = clamp(CGFloat(workspace.dockY) * height + drag.height,
                                    minY, maxY)

                BrowserDockContent(workspace: workspace, session: workspace.active)
                    .padding(10)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .updating($drag) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let finalX = clamp(
                                    CGFloat(workspace.dockX) * width + value.translation.width,
                                    minX, maxX
                                )
                                let finalY = clamp(
                                    CGFloat(workspace.dockY) * height + value.translation.height,
                                    minY, maxY
                                )
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    workspace.moveDock(x: Double(finalX / max(width, 1)),
                                                       y: Double(finalY / max(height, 1)))
                                }
                                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            }
                    )
                    .position(x: centerX, y: centerY)
                    .accessibilityHint("Drag to move; tap to open. Position is saved for this chat.")
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }
}

private struct BrowserDockContent: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var session: BrowserSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "globe.americas.fill")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.caption).fontWeight(.semibold).lineLimit(1)
                    Text(session.status).font(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if session.isLoading { ProgressView().controlSize(.mini) }
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
            }
            .padding(10)
            if let screenshot = session.thumbnail {
                Image(uiImage: screenshot)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 244, height: 120)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        Text("\(workspace.sessions.count) browsers")
                            .font(.caption2).padding(5)
                            .background(.regularMaterial, in: Capsule())
                            .padding(5)
                    }
            } else {
                HStack {
                    Image(systemName: "globe").font(.title2)
                    Text("Live browser · \(workspace.sessions.count) tabs").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 244)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.cyan.opacity(0.25)))
        .shadow(radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 17))
        .onTapGesture { workspace.open() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Expand live browser: \(session.title)")
    }
}

@MainActor
struct BrowserFullScreenView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearLogins = false
    @State private var confirmCloseChatTabs = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(workspace.sessions, id: \.id) { session in
                                Button {
                                    workspace.select(session.id)
                                } label: {
                                    Text(session.title.isEmpty ? "Browser" : String(session.title.prefix(25)))
                                        .font(.caption).lineLimit(1)
                                        .padding(.horizontal, 11).padding(.vertical, 8)
                                        .background(workspace.selectedID == session.id
                                            ? Color.cyan.opacity(0.2) : Color.secondary.opacity(0.12),
                                            in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        workspace.closeTab(session.id)
                                    } label: {
                                        Label("Close browser tab", systemImage: "xmark")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    Button {
                        let _ = workspace.newBrowser()
                    } label: { Image(systemName: "plus.square.on.square") }
                    .padding(.trailing)
                    .accessibilityLabel("New browser")
                }
                BrowserPage(session: workspace.active, workspace: workspace)
                    .id(workspace.active.id)
                if workspace.active.userControl || workspace.awaitingHuman {
                    Button {
                        workspace.takeBackControl()
                    } label: {
                        Label("Done — Return control to AI", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                } else {
                    HStack {
                        Image(systemName: "eye")
                        Text("View and scroll freely. Interact with the page to take control.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
            }
            .navigationTitle("Live Browsers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("Close all tabs in this chat", role: .destructive) {
                            confirmCloseChatTabs = true
                        }
                        Button("Clear browser sign-ins and website data", role: .destructive) {
                            confirmClearLogins = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        workspace.fullScreen = false
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Close this chat's browsers?",
                                isPresented: $confirmCloseChatTabs) {
                Button("Close all chat browser tabs", role: .destructive) {
                    workspace.closeCurrentChatTabs()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only tabs and saved page state for this chat are cleared. Website logins in other chats remain available.")
            }
            .confirmationDialog("Clear all browser logins?", isPresented: $confirmClearLogins,
                                titleVisibility: .visible) {
                Button("Clear website logins and cookies", role: .destructive) {
                    Task { await workspace.clearBrowserLogins() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs you out of websites within ASSistant across all browser tabs. It does not affect Safari or separately connected Google/Spotify OAuth accounts.")
            }
        }
    }
}

@MainActor
private struct BrowserPage: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var workspace: BrowserWorkspace
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                TextField("Search or enter URL", text: $address)
                    .font(.caption)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($editingAddress)
                    .onSubmit { navigateManually() }
                    .padding(8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)

            if session.requiresHuman {
                VStack(spacing: 5) {
                    Label("ASSistant needs your help", systemImage: "person.fill.questionmark")
                        .font(.headline)
                    Text(session.handoffReason)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Text("Complete the sign-in, security code or CAPTCHA below, then tap Return control to AI.")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.orange.opacity(0.13))
            }

            if session.isLoading { ProgressView().frame(maxWidth: .infinity) }
            BrowserSurface(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        }
        .onAppear { address = session.currentURL }
        .onChange(of: session.currentURL) { updated in
            if !editingAddress { address = updated }
        }
        .onChange(of: editingAddress) { isFocused in
            if isFocused { session.userControl = true }
        }
    }

    private func navigateManually() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        editingAddress = false
        do {
            try session.navigateAsUser(value)
        } catch {
            session.lastError = error.localizedDescription
        }
    }
}
