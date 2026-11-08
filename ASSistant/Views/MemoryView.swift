import SwiftUI

@MainActor
struct MemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var edit: MemoryItem?
    @State private var adding = false
    @State private var selectedCategory = "All"
    @State private var recentDays = 0
    @State private var expandedIDs: Set<UUID> = []

    private var categories: [String] {
        ["All"] + Array(Set(store.memories.map { $0.category ?? $0.kind })).sorted()
    }

    private var filtered: [MemoryItem] {
        store.memories.filter { memory in
            (selectedCategory == "All" || (memory.category ?? memory.kind) == selectedCategory) &&
            (recentDays == 0 || memory.updatedAt >= Date().addingTimeInterval(-Double(recentDays) * 86400)) &&
            (query.isEmpty || [memory.title ?? "", memory.text, memory.category ?? memory.kind, memory.scope]
                .contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { adding = true } label: { Label("Add memory", systemImage: "plus") }
                    HStack {
                        Text("Saved facts")
                        Spacer()
                        Text("\(store.memories.count)").foregroundColor(.secondary)
                    }
                }
                Section("Categories and timeframe") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categories, id: \.self) { name in Text(name).tag(name) }
                    }
                    Picker("Saved within", selection: $recentDays) {
                        Text("Any time").tag(0)
                        Text("Last 7 days").tag(7)
                        Text("Last 30 days").tag(30)
                        Text("Last year").tag(365)
                    }
                    Text("\(filtered.count) matching memories, \(categories.count - 1) categories")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Long-term memories") {
                    ForEach(filtered) { memory in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(memory.category ?? memory.kind.capitalized).font(.caption).fontWeight(.semibold)
                                Text(memory.scope).font(.caption).foregroundColor(.secondary)
                                Spacer()
                                if memory.pinned { Image(systemName: "pin.fill").foregroundColor(.blue) }
                                Button { edit = memory } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless)
                            }
                            Button {
                                if expandedIDs.contains(memory.id) { expandedIDs.remove(memory.id) }
                                else { expandedIDs.insert(memory.id) }
                            } label: {
                                HStack {
                                    Text(memory.title ?? MemoryEngine.shortTitle(memory.text))
                                        .font(.subheadline).fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: expandedIDs.contains(memory.id) ? "chevron.up" : "chevron.down")
                                }
                            }
                            .buttonStyle(.plain)
                            if expandedIDs.contains(memory.id) {
                                Text(memory.text).font(.body).textSelection(.enabled)
                                Text("ID: \(memory.id.uuidString)")
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            HStack {
                                Text("Priority \(Int(memory.importance * 100))%")
                                Spacer()
                                Text(memory.updatedAt, style: .date)
                            }
                            .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) { store.delete(memory.id, kind: "memory") } label: { Text("Forget") }
                        }
                    }
                }
                Section("Context behavior") {
                    Text("The complete chat remains saved locally and may sync through iCloud. The AI receives recent turns and only relevant saved memories. Sensitive facts aren't auto-injected.")
                        .font(.footnote).foregroundColor(.secondary)
                    if let diagnostic = store.lastDiagnostic {
                        Text("Last prompt: ~\(diagnostic.inputTokens) input tokens, \(diagnostic.memoriesUsed) memories, \(diagnostic.messagesUsed) recent turns.")
                            .font(.caption)
                    }
                }
            }
            .searchable(text: $query)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Memory")
            .sheet(isPresented: $adding) {
                MemoryEditor(memory: MemoryItem(text: ""), isNew: true).environmentObject(store)
            }
            .sheet(item: $edit) { memory in
                MemoryEditor(memory: memory, isNew: false).environmentObject(store)
            }
        }
    }
}

private struct MemoryEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var memory: MemoryItem
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Memory") {
                    TextField("Short title", text: Binding(
                        get: { memory.title ?? "" },
                        set: { memory.title = $0 }
                    ))
                    TextField("Category (e.g. Preferences, Work)", text: Binding(
                        get: { memory.category ?? "" },
                        set: { memory.category = $0 }
                    ))
                    TextEditor(text: $memory.text).frame(minHeight: 130)
                    Picker("Type", selection: $memory.kind) {
                        ForEach(["fact", "preference", "goal", "project", "person", "decision", "routine", "procedure", "task", "timeline"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    TextField("Scope (global, chat:UUID, agent:UUID)", text: $memory.scope)
                    Toggle("Pinned", isOn: $memory.pinned)
                    Toggle("Sensitive (never auto-inject)", isOn: $memory.isSensitive)
                    VStack(alignment: .leading) {
                        Text("Importance: \(Int(memory.importance * 100))%")
                        Slider(value: $memory.importance, in: 0...1, step: 0.05)
                    }
                }
                if let source = memory.sourceMessageID {
                    Section("Source message") { Text(source.uuidString).font(.footnote).textSelection(.enabled) }
                }
            }
            .navigationTitle(isNew ? "New Memory" : "Edit Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        memory.text = memory.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        memory.updatedAt = .now
                        if memory.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            memory.title = MemoryEngine.shortTitle(memory.text)
                        }
                        if memory.category?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                            memory.category = memory.kind.capitalized
                        }
                        if !memory.text.isEmpty { store.save(memory); dismiss() }
                    }
                }
            }
        }
    }
}
