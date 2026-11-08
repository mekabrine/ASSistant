import SwiftUI
import WebKit

/// Multiple foreground WKWebView tabs with one shared persistent WebKit cookie
/// store. Sessions are shared across all chats, but NOT with Safari.
@MainActor
final class BrowserWorkspace: ObservableObject {
    @Published private(set) var tabs: [BrowserSession] = []
    @Published var selectedID: UUID?
    @Published var fullScreen = false

    init() {
        let initial = BrowserSession()
        tabs = [initial]
        selectedID = initial.id
    }

    var current: BrowserSession {
        tabs.first(where: { $0.id == selectedID }) ?? tabs[0]
    }

    func choose(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    @discardableResult
    func newTab(url: String? = nil) -> BrowserSession {
        let tab = BrowserSession()
        tabs.append(tab)
        selectedID = tab.id
        if let url {
            Task { _ = try? await tab.navigate(url) }
        }
        return tab
    }

    func selectForAgent(_ tab: BrowserSession) {
        selectedID = tab.id
        tab.visible = true
    }

    func releaseToAgent() {
        for tab in tabs {
            tab.returnToAgent()
        }
    }

    func close(_ id: UUID) {
        guard tabs.count > 1 else {
            current.close()
            return
        }
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.close()
        }
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs.first?.id }
    }
}

struct BrowserWorkspaceDock: View {
    @ObservedObject var workspace: BrowserWorkspace

    var body: some View {
        if !workspace.fullScreen && workspace.tabs.contains(where: { $0.visible }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Live browsing", systemImage: "globe")
                        .font(.caption).fontWeight(.semibold)
                    Spacer()
                    Button {
                        workspace.fullScreen = true
                    } label: {
                        Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Open browser full screen without taking control")
                    Button { workspace.current.visible = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Hide browser preview")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            Button {
                                workspace.choose(tab.id)
                            } label: {
                                Text(tab.title.isEmpty ? "Tab" : tab.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(maxWidth: 108)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(
                                        tab.id == workspace.selectedID ?
                                            Color.cyan.opacity(0.20) : Color.secondary.opacity(0.09),
                                        in: Capsule()
                                    )
                            }
                        }
                    }
                }
                Text(workspace.current.currentURL.isEmpty ?
                     workspace.current.status : workspace.current.currentURL)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                if workspace.current.waitingForHuman {
                    Label("Needs your help", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                    Button {
                        workspace.fullScreen = true
                    } label: {
                        Text("Complete verification").font(.subheadline).fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(9)
                    }.buttonStyle(.borderedProminent)
                } else if workspace.current.userControl {
                    Button("Return control to AI") { workspace.releaseToAgent() }
                        .font(.caption).buttonStyle(.borderedProminent)
                }
            }
            .padding(13)
            .frame(width: 270)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .stroke(Color.cyan.opacity(0.22)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(10)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

struct BrowserFullScreenView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @State private var address = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(workspace.tabs) { tab in
                            HStack(spacing: 4) {
                                Button {
                                    workspace.choose(tab.id)
                                    address = tab.currentURL
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title.isEmpty ? "New tab" : tab.title)
                                            .lineLimit(1)
                                            .font(.caption).fontWeight(.semibold)
                                        Text(tab.userControl ? "You" :
                                            (tab.waitingForHuman ? "Help needed" : "AI"))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Button {
                                    workspace.close(tab.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Close browser tab")
                            }
                            .padding(8)
                            .background(
                                workspace.selectedID == tab.id ?
                                    Color.cyan.opacity(0.18) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 11)
                            )
                        }
                        Button {
                            let tab = workspace.newTab()
                            address = tab.currentURL
                        } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                            .accessibilityLabel("New browser tab")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
                HStack(spacing: 12) {
                    Button { workspace.current.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    Button { workspace.current.goForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    TextField("HTTPS address or search", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                        .padding(8)
                        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                        .onSubmit { visitAddress() }
                    Button { workspace.current.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 8)

                if workspace.current.waitingForHuman {
                    Text(workspace.current.handoffReason)
                        .font(.subheadline).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                        .padding(9)
                }
                BrowserSurface(session: workspace.current)
                    .id(workspace.selectedID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.current.userControl || workspace.current.waitingForHuman {
                    Button {
                        workspace.releaseToAgent()
                    } label: {
                        Label("Return control to AI and continue", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                } else {
                    HStack {
                        Image(systemName: "hand.draw")
                        Text("Scroll freely. Tapping or editing a page takes control.")
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Back to chat") { workspace.fullScreen = false }
                }
            }
            .onAppear { address = workspace.current.currentURL }
            .onChange(of: workspace.current.currentURL) { address = $0 }
        }
    }

    private func visitAddress() {
        let request = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        let tab = workspace.current
        Task {
            tab.returnToAgent()
            if request.hasPrefix("https://") {
                _ = try? await tab.navigate(request)
            } else if request.contains(".") && !request.contains(" ") {
                _ = try? await tab.navigate("https://" + request)
            } else {
                _ = try? await tab.search(request)
            }
            // A manually-entered address is a user action.
            tab.userControl = true
        }
    }
}
