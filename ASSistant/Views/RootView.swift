import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var browsers = BrowserWorkspace.shared
    @State private var selectedChatID: UUID?
    @State private var chatSidebar: NavigationSplitViewVisibility = .all
    @State private var phoneSidebarOpen = false

    var body: some View {
        TabView {
            Group {
                if horizontalSizeClass == .compact {
                    compactChatLayout
                } else {
                    NavigationSplitView(columnVisibility: $chatSidebar) {
                        ChatSidebarView(selectedChatID: $selectedChatID)
                            .environmentObject(store)
                            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
                    } detail: {
                        ChatView(chatID: $selectedChatID, browser: browsers) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                chatSidebar = chatSidebar == .all ? .detailOnly : .all
                            }
                        }
                        .environmentObject(store)
                    }
                }
            }
            .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            TasksView()
                .tabItem { Label("Tasks", systemImage: "checkmark.circle.fill") }
            AppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
            MemoryView()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .onAppear {
            if horizontalSizeClass == .regular { chatSidebar = .all }
            browsers.activateChat(selectedChatID)
        }
        .onChange(of: horizontalSizeClass) { sizeClass in
            if sizeClass == .regular {
                phoneSidebarOpen = false
                chatSidebar = .all
            }
        }
        .onChange(of: selectedChatID) { value in
            browsers.activateChat(value)
            if phoneSidebarOpen {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    phoneSidebarOpen = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didEnterBackgroundNotification
        )) { _ in
            browsers.saveNow()
        }
        .tint(.cyan)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .top) {
            if !store.database.ready {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.syncStatus).font(.caption).lineLimit(2)
                }
                .padding(9)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// On iPhone, use an overlay instead of NavigationSplitView's implicit
    /// compact navigation. Opening the sidebar never changes the selected chat.
    private var compactChatLayout: some View {
        ZStack(alignment: .leading) {
            ChatView(chatID: $selectedChatID, browser: browsers) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88)) {
                    phoneSidebarOpen.toggle()
                }
            }
            .environmentObject(store)

            if phoneSidebarOpen {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            phoneSidebarOpen = false
                        }
                    }
                    .transition(.opacity)
                    .accessibilityLabel("Dismiss conversation sidebar")

                GeometryReader { geo in
                    HStack(spacing: 0) {
                        NavigationStack {
                            ChatSidebarView(selectedChatID: $selectedChatID) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    phoneSidebarOpen = false
                                }
                            }
                                .environmentObject(store)
                                .toolbar {
                                    ToolbarItem(placement: .navigationBarLeading) {
                                        Button {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                phoneSidebarOpen = false
                                            }
                                        } label: {
                                            Label("Close", systemImage: "xmark")
                                        }
                                    }
                                }
                        }
                        .frame(width: min(350, geo.size.width * 0.88))
                        .background(.regularMaterial)
                        .clipShape(UnevenSidebarShape())
                        .shadow(color: .black.opacity(0.22), radius: 22, x: 6, y: 0)

                        Spacer(minLength: 0)
                    }
                }
                .transition(.move(edge: .leading))
                .zIndex(1)
            }
        }
    }
}

/// Compatible with iOS 16; don't rely on iOS 17's UnevenRoundedRectangle.
private struct UnevenSidebarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let corners: UIRectCorner = [.topRight, .bottomRight]
        let bezier = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                                  cornerRadii: CGSize(width: 18, height: 18))
        return Path(bezier.cgPath)
    }
}
