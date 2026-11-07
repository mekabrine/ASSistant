import SwiftUI

@MainActor
struct AgentsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: AgentProfile?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { creating = true } label: { Label("Add agent", systemImage: "plus") }
                }
                ForEach(store.agents) { agent in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(agent.name).font(.headline)
                            Spacer()
                            Button("Edit") { editing = agent }.buttonStyle(.bordered)
                        }
                        Text(agent.instructions).font(.subheadline).lineLimit(3).foregroundColor(.secondary)
                        Text("\(agent.allowedTools.count) enabled tool categories").font(.caption).foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { store.delete(agent.id, kind: "agent") } label: { Text("Delete") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Agents")
            .sheet(isPresented: $creating) {
                AgentEditor(agent: AgentProfile(), isNew: true)
                    .environmentObject(store)
            }
            .sheet(item: $editing) { agent in
                AgentEditor(agent: agent, isNew: false)
                    .environmentObject(store)
            }
        }
    }
}

private struct AgentEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State var agent: AgentProfile
    let isNew: Bool
    private let tools = ["reminder", "calendar", "contacts", "location", "clipboard",
                         "notification", "htmlapp", "web", "speak"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $agent.name)
                    TextEditor(text: $agent.instructions).frame(minHeight: 130)
                }
                Section("Default model") {
                    Picker("Provider", selection: $agent.providerID) {
                        Text("Use default provider").tag(nil as UUID?)
                        ForEach(store.providers) { provider in
                            Text("\(provider.name) · \(provider.model)").tag(Optional(provider.id))
                        }
                    }
                }
                Section("Allowed tools") {
                    ForEach(tools, id: \.self) { name in
                        Toggle(name.capitalized, isOn: Binding(
                            get: { agent.allowedTools.contains(name) },
                            set: { enabled in
                                if enabled && !agent.allowedTools.contains(name) { agent.allowedTools.append(name) }
                                else if !enabled { agent.allowedTools.removeAll { $0 == name } }
                            }
                        ))
                    }
                    Text("Even allowed device tools require an explicit action approval and iOS system permission.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle(isNew ? "New Agent" : "Edit Agent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        agent.name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !agent.name.isEmpty { store.save(agent); dismiss() }
                    }
                }
            }
        }
    }
}
