import SwiftUI

@MainActor
struct ChatSidebarView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedChatID: UUID?
    @State private var search = ""
    @State private var renameTarget: ChatThread?
    @State private var proposedName = ""
    @AppStorage("pinnedChatIDs") private var pinnedIDs = ""

    private var pinned: Set<String> {
        Set(pinnedIDs.split(separator: ",").map(String.init))
    }

    private var chats: [ChatThread] {
        store.chats.filter { chat in
            !chat.archived && (search.isEmpty ||
             chat.title.localizedCaseInsensitiveContains(search))
        }
    }

    private func subset(_ date: Date, category: String) -> Bool {
        let calendar = Calendar.current
        switch category {
        case "Today": return calendar.isDateInToday(date)
        case "Yesterday": return calendar.isDateInYesterday(date)
        case "This week":
            return date > Calendar.current.date(byAdding: .day, value: -7, to: .now)!
                && !calendar.isDateInToday(date) && !calendar.isDateInYesterday(date)
        default:
            return date <= Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        }
    }

    var body: some View {
        List(selection: $selectedChatID) {
            Section {
                Button {
                    let chat = store.createChat()
                    selectedChatID = chat.id
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus.square.fill")
                            .font(.title3)
                        Text("New chat").fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "square.and.pencil")
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!store.database.ready)
            }

            if !chats.filter({ pinned.contains($0.id.uuidString) }).isEmpty {
                Section("Pinned") {
                    ForEach(chats.filter({ pinned.contains($0.id.uuidString) })) { chat in
                        row(chat)
                    }
                }
            }

            ForEach(["Today", "Yesterday", "This week", "Earlier"], id: \.self) { period in
                let entries = chats.filter {
                    !pinned.contains($0.id.uuidString) && subset($0.updatedAt, category: period)
                }
                if !entries.isEmpty {
                    Section(period) {
                        ForEach(entries) { chat in row(chat) }
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Chats and memories stay on this device unless iCloud sync is enabled.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, prompt: "Search conversations")
        .navigationTitle("ASSistant")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let chat = store.createChat()
                    selectedChatID = chat.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
            }
        }
        .alert("Rename conversation", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Chat name", text: $proposedName)
            Button("Save") {
                if var chat = renameTarget {
                    let clean = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { chat.title = String(clean.prefix(80)); store.save(chat) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private func row(_ chat: ChatThread) -> some View {
        HStack(spacing: 9) {
            Image(systemName: pinned.contains(chat.id.uuidString) ? "pin.fill" : "bubble.left")
                .foregroundStyle(pinned.contains(chat.id.uuidString) ? Color.cyan : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title).lineLimit(2)
                Text(chat.updatedAt, style: .date)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .tag(chat.id)
        .contentShape(Rectangle())
        .onTapGesture { selectedChatID = chat.id }
        .contextMenu {
            Button {
                proposedName = chat.title
                renameTarget = chat
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                var all = pinned
                if all.contains(chat.id.uuidString) { all.remove(chat.id.uuidString) }
                else { all.insert(chat.id.uuidString) }
                pinnedIDs = all.sorted().joined(separator: ",")
            } label: {
                Label(pinned.contains(chat.id.uuidString) ? "Unpin" : "Pin", systemImage: "pin")
            }
            Button {
                var copy = chat
                copy.archived = true
                store.save(copy)
                if selectedChatID == chat.id { selectedChatID = nil }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) {
                store.delete(chat.id, kind: "chat")
                if selectedChatID == chat.id { selectedChatID = nil }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
