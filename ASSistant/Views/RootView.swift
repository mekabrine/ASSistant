import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            AgentsView()
                .tabItem { Label("Agents", systemImage: "person.2") }
            MemoryView()
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checkmark.circle") }
            AppsView()
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.blue)
        .overlay(alignment: .top) {
            if !store.database.ready {
                Text(store.syncStatus)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.18))
            }
        }
    }
}
