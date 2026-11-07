import SwiftUI

@MainActor
struct MemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var edit: MemoryItem?
    @State private var adding = false

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
                Section("Long-term memories") {
                    ForEach(store.memories.filter { memory in
                        query.isEmpty || memory.text.localizedCaseInsensitiveContains(query) ||
                        memory.kind.localizedCaseInsensitiveContains(query) ||
                        memory.scope.localizedCaseInsensitiveContains(query)
                    }) { memory in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(memory.kind.capitalized).font(.caption).fontWeight(.semibold)
                                Text(memory.scope).font(.caption).foregroundColor(.secondary)
                                Spacer()
                                if memory.pinned { Image(systemName: "pin.fill").foregroundColor(.blue) }
                                Button { edit = memory } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless)
                            }
                            Text(memory.text).font(.body).textSelection(.enabled)
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
                        if !memory.text.isEmpty { store.save(memory); dismiss() }
                    }
                }
            }
        }
    }
}
