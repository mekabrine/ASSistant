import Foundation
import SwiftUI
import WebKit
import Combine

/// Browser windows share the app's persistent WebKit website data store so
/// logins remain available across chats. They never borrow Safari cookies.
@MainActor
final class BrowserWorkspace: ObservableObject {
    static let shared = BrowserWorkspace()
    @Published private(set) var sessions: [BrowserSession] = [BrowserSession()]
    @Published var selectedID: UUID?
    @Published var fullScreen = false
    @Published var awaitingHuman = false
    @Published var handoffBrowserID: UUID?
    private var observers: [UUID: AnyCancellable] = [:]

    init() {
        selectedID = sessions.first?.id
        if let first = sessions.first { observe(first) }
    }

    private func observe(_ tab: BrowserSession) {
        observers[tab.id] = tab.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var active: BrowserSession {
        sessions.first(where: { $0.id == selectedID }) ?? sessions[0]
    }

    var anyVisible: Bool { sessions.contains(where: { $0.visible }) }

    @discardableResult
    func newBrowser() -> BrowserSession {
        if sessions.count >= 6 {
            // Bound live web processes, preserving all cookies.
            if let old = sessions.first(where: { $0.id != selectedID && !$0.activeAgent }) {
                old.close()
                observers[old.id] = nil
                sessions.removeAll { $0.id == old.id }
            }
        }
        let item = BrowserSession()
        item.visible = true
        sessions.append(item)
        observe(item)
        selectedID = item.id
        return item
    }

    func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
        active.visible = true
    }

    func open() {
        active.visible = true
        fullScreen = true
    }

    func takeBackControl() {
        if let id = handoffBrowserID, let target = sessions.first(where: { $0.id == id }) {
            target.returnControl()
            selectedID = target.id
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
        for browser in sessions { browser.returnControl() }
        awaitingHuman = false
        handoffBrowserID = nil
    }

    func stopAll() {
        for browser in sessions { browser.stop() }
    }

    func list() -> String {
        sessions.enumerated().map { i, item in
            "\(i + 1). id=\(item.id.uuidString) \(String(item.title.prefix(70))) \(item.currentURL)"
        }.joined(separator: "\n")
    }

    func choose(_ value: String?) throws -> BrowserSession {
        guard let value, let id = UUID(uuidString: value),
              let candidate = sessions.first(where: { $0.id == id }) else {
            throw BrowserFailure.invalidLink
        }
        select(candidate.id)
        return candidate
    }

    /// Agent stays paused while the user completes account/CAPTCHA actions.
    /// No password, security code, input contents or cookies enter the prompt.
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

    func clearBrowserLogins() async {
        for tab in sessions { tab.close() }
        observers.removeAll()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        sessions = [BrowserSession()]
        observe(sessions[0])
        selectedID = sessions[0].id
        awaitingHuman = false
        handoffBrowserID = nil
        fullScreen = false
    }
}

@MainActor
struct BrowserDock: View {
    @ObservedObject var workspace: BrowserWorkspace

    var body: some View {
        if workspace.anyVisible && !workspace.fullScreen {
            BrowserDockContent(workspace: workspace, session: workspace.active)
                .padding(12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
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
