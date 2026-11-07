import SwiftUI

@MainActor
struct TasksView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingForm = false
    @State private var errorText = ""
    @State private var dueOnly = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingForm = true } label: { Label("New task", systemImage: "plus") }
                    Toggle("Show unfinished only", isOn: $dueOnly)
                }
                Section("Tracked tasks") {
                    ForEach(store.tasks.filter { !dueOnly || $0.state != "done" }) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button {
                                    var updated = item
                                    updated.state = item.state == "done" ? "open" : "done"
                                    updated.updatedAt = .now
                                    store.save(updated)
                                    if updated.state == "done" { DeviceTools.shared.cancelNotification(id: item.id) }
                                } label: {
                                    Image(systemName: item.state == "done" ? "checkmark.circle.fill" : "circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(item.state == "done" ? .green : .blue)
                                Text(item.title).font(.headline)
                                Spacer()
                            }
                            if !item.details.isEmpty { Text(item.details).font(.subheadline).foregroundColor(.secondary) }
                            if let due = item.dueDate {
                                Text(due, style: .date).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                DeviceTools.shared.cancelNotification(id: item.id)
                                store.delete(item.id, kind: "task")
                            } label: { Text("Delete") }
                        }
                    }
                }
                if !errorText.isEmpty { Text(errorText).foregroundColor(.red) }
                Section("About automations") {
                    Text("Tasks and local alerts work while the app is closed. Actual autonomous AI work needs a separate cloud worker because iOS does not permit unrestricted background execution.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Tasks")
            .sheet(isPresented: $showingForm) {
                TaskEditor { title, details, due, schedule in
                    let item = AgentTask(title: title, details: details, dueDate: due)
                    store.save(item)
                    if schedule, let due {
                        Task {
                            do {
                                try await DeviceTools.shared.scheduleNotification(
                                    id: item.id, title: title, body: details, at: due)
                            } catch { errorText = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }
}

private struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, String, Date?, Bool) -> Void
    @State private var title = ""
    @State private var details = ""
    @State private var hasDueDate = false
    @State private var due = Date().addingTimeInterval(3600)
    @State private var notify = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextEditor(text: $details).frame(minHeight: 90)
                Toggle("Has due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Toggle("Local notification", isOn: $notify)
                }
            }
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            onSave(name, details, hasDueDate ? due : nil, hasDueDate && notify)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
