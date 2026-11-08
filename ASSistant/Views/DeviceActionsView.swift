import SwiftUI
import MessageUI

@MainActor
struct DeviceActionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @State private var shortcutName = ""
    @State private var shortcutInput = ""
    @State private var phoneNumber = ""
    @State private var messageBody = ""
    @State private var contactQuery = ""
    @State private var smsDraft: SMSDraft?
    @State private var status = ""
    @State private var activeOperation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Run an Apple Shortcut") {
                    TextField("Exact installed Shortcut name", text: $shortcutName)
                    TextField("Optional text input", text: $shortcutInput)
                    Button {
                        perform("run_shortcut") {
                            try await NativeActions.runShortcut(name: shortcutName, input: shortcutInput)
                        }
                    } label: { Label("Open Shortcut", systemImage: "bolt.fill") }
                        .disabled(activeOperation || shortcutName.isEmpty)
                    Text("iOS runs Shortcuts outside ASSistant. The app can open a named Shortcut, but cannot enumerate private Shortcuts or verify completion. Shortcuts may ask for confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Phone and Messages") {
                    TextField("Phone number (include country code)", text: $phoneNumber)
                        .keyboardType(.phonePad)
                    Button {
                        perform("place_call") {
                            try await NativeActions.openPhone(phoneNumber)
                        }
                    } label: { Label("Open Phone call request", systemImage: "phone.arrow.up.right.fill") }
                        .disabled(activeOperation || phoneNumber.isEmpty)
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 92)
                    Button {
                        Task {
                            do {
                                guard MFMessageComposeViewController.canSendText() else {
                                    throw NativeActionError.messagesUnavailable
                                }
                                let destination = try await NativeActions.resolvePhone(phoneNumber)
                                smsDraft = SMSDraft(recipient: destination, message: messageBody)
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    } label: { Label("Compose SMS / iMessage", systemImage: "message.fill") }
                        .disabled(phoneNumber.isEmpty || messageBody.isEmpty)
                    Text("You must press Send yourself in the Apple Messages composer. Opening Phone does not confirm that a call connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Find a person in Contacts") {
                    TextField("Contact name", text: $contactQuery)
                    Button {
                        perform("find_contacts") {
                            try await NativeActions.contactMatches(contactQuery)
                        }
                    } label: { Label("Look up contact", systemImage: "person.crop.circle.badge.questionmark") }
                        .disabled(activeOperation || contactQuery.isEmpty)
                    Text("Access to saved contacts needs the iOS permission prompt. Only lookups that you initiate here or explicitly approve as agent tools are performed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if activeOperation {
                    Section { ProgressView("Performing action…") }
                }
                if !status.isEmpty {
                    Section("Last result") {
                        Text(status).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Device Actions")
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $smsDraft) { draft in
                MessageComposeSheet(draft: draft) { outcome in
                    store.save(ToolAudit(tool: "compose_sms", detail: draft.recipient,
                                         approved: true, result: outcome))
                    status = outcome
                    smsDraft = nil
                }
            }
        }
    }

    private func perform(_ name: String, operation: @escaping () async throws -> String) {
        activeOperation = true
        status = ""
        Task {
            do {
                let value = try await operation()
                status = value
                store.save(ToolAudit(tool: name, detail: "User initiated in Settings",
                                     approved: true, result: value))
            } catch {
                status = error.localizedDescription
                store.save(ToolAudit(tool: name, detail: "User initiated in Settings",
                                     approved: true, result: status))
            }
            activeOperation = false
        }
    }
}
