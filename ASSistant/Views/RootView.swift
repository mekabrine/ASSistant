import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            ChatView()
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
}
