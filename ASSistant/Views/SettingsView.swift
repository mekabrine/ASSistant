import SwiftUI
import CoreLocation
import CloudKit

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var createProvider = false
    @State private var editingProvider: ProviderProfile?
    @State private var gistToken = ""
    @State private var publisherToken = ""
    @State private var testResult = ""
    @State private var permissionResult = ""
    @AppStorage("publisherEndpoint") private var publisherEndpoint = ""
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = true
    @AppStorage("autoSummaryEnabled") private var autoSummaryEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section("AI providers") {
                    Button { createProvider = true } label: { Label("Add provider", systemImage: "plus") }
                    if store.providers.isEmpty {
                        Text("Configure your own API endpoint, model and API key to start chatting.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(store.providers) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(.headline)
                                Text("\(profile.adapter) · \(profile.model)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Edit") { editingProvider = profile }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                KeychainStore.delete("provider.\(profile.id.uuidString)")
                                store.delete(profile.id, kind: "provider")
                            } label: { Text("Delete") }
                        }
                    }
                }
                Section("iCloud synchronization") {
                    Toggle("Sync data with iCloud", isOn: $cloudSyncEnabled)
                    Text(store.syncStatus).font(.caption)
                    Text("Restart to apply a sync-mode change. Full CloudKit synchronization requires a valid Apple signing profile and CloudKit entitlement; an unsigned IPA alone cannot use iCloud. API keys are always device-local.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section("Context and memory") {
                    Toggle("Auto-summarize longer chats (extra AI calls)", isOn: $autoSummaryEnabled)
                    Text("Memories are selectively retrieved. Sensitive memories are not auto-included. Full chat history is stored for search and can sync.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section("HTML publishing") {
                    Text("By default ASSistant publishes generated HTML as an unlisted GitHub Gist. Unlisted does not mean private.")
                        .font(.footnote).foregroundColor(.secondary)
                    SecureField("GitHub Gist token (gist scope)", text: $gistToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button(KeychainStore.get("github.publisher") == nil ? "Save GitHub token" : "Replace GitHub token") {
                        do {
                            try KeychainStore.put(gistToken, for: "github.publisher")
                            gistToken = ""
                            testResult = "Publishing token saved on this device."
                        } catch { testResult = error.localizedDescription }
                    }.disabled(gistToken.isEmpty)
                    TextField("Optional custom HTTPS publishing endpoint", text: $publisherEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                    SecureField("Custom endpoint bearer token (optional)", text: $publisherToken)
                    Button("Save custom endpoint token") {
                        do {
                            try KeychainStore.put(publisherToken, for: "publisher.customToken")
                            publisherToken = ""
                            testResult = "Custom endpoint token saved."
                        } catch { testResult = error.localizedDescription }
                    }.disabled(publisherToken.isEmpty)
                    Text("Custom endpoint contract: POST text/html, return JSON {\"url\":\"https://public-host/file.html\"}.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Section("Device permissions and native tools") {
                    Button("Request notifications permission") {
                        Task { await runPermission { try await DeviceTools.shared.requestNotifications(); return "Notifications authorized" } }
                    }
                    Button("Request reminders access") {
                        Task { await runPermission { try await DeviceTools.shared.authorizeReminders(); return "Reminders authorized" } }
                    }
                    Button("Request calendar access") {
                        Task { await runPermission { try await DeviceTools.shared.authorizeCalendar(); return "Calendar authorized" } }
                    }
                    Button("Request contacts access") {
                        Task { await runPermission { "Contacts available: \(try await DeviceTools.shared.contactsCount())" } }
                    }
                    Button("Request current location") {
                        Task {
                            await runPermission {
                                let point = try await DeviceTools.shared.currentLocation()
                                return "\(point.coordinate.latitude), \(point.coordinate.longitude)"
                            }
                        }
                    }
                    if !permissionResult.isEmpty { Text(permissionResult).font(.footnote) }
                    Text("Permission buttons request OS consent when needed. AI tool actions still require approval.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("About prototype") {
                    Text("ASSistant for iOS 16+")
                    Text("GitHub Actions is manual-only. Unsigned IPA builds require appropriate signing for normal installation and iCloud features.")
                        .font(.footnote).foregroundColor(.secondary)
                    if !testResult.isEmpty { Text(testResult).font(.footnote) }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $createProvider) {
                ProviderEditor(profile: ProviderProfile(), isNew: true).environmentObject(store)
            }
            .sheet(item: $editingProvider) { provider in
                ProviderEditor(profile: provider, isNew: false).environmentObject(store)
            }
        }
    }

    private func runPermission(_ operation: @escaping () async throws -> String) async {
        do { permissionResult = try await operation() }
        catch { permissionResult = error.localizedDescription }
    }
}

@MainActor
private struct ProviderEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: ProviderProfile
    let isNew: Bool
    @State private var apiKey = ""
    @State private var connectionMessage = ""
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API connection") {
                    TextField("Display name", text: $profile.name)
                    Picker("Protocol", selection: $profile.adapter) {
                        Text("OpenAI-compatible").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Gemini").tag("gemini")
                    }
                    TextField("Base URL", text: $profile.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Model ID", text: $profile.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Picker("Authentication", selection: $profile.authMode) {
                        Text("Bearer").tag("bearer")
                        Text("Custom header").tag("header")
                        Text("None").tag("none")
                    }
                    if profile.authMode == "header" {
                        TextField("Header name", text: $profile.apiKeyHeader)
                            .textInputAutocapitalization(.never)
                    }
                    SecureField(KeychainStore.get("provider.\(profile.id.uuidString)") == nil ? "API key" : "Replace saved API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("API keys are stored in iOS Keychain only and are not synced to other devices.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("Model configuration") {
                    Stepper("Context budget: \(profile.maxContextTokens)", value: $profile.maxContextTokens,
                            in: 2048...200000, step: 1024)
                    Stepper("Max output: \(profile.maxOutputTokens)", value: $profile.maxOutputTokens,
                            in: 128...32768, step: 128)
                    VStack {
                        Text("Temperature: \(profile.temperature.formatted(.number.precision(.fractionLength(1))))")
                        Slider(value: $profile.temperature, in: 0...2, step: 0.1)
                    }
                    Toggle("Enabled", isOn: $profile.enabled)
                }
                Section("Test") {
                    Button(testing ? "Testing…" : "Test with a short prompt") { test() }
                        .disabled(testing || profile.model.isEmpty)
                    if !connectionMessage.isEmpty { Text(connectionMessage).font(.footnote) }
                }
            }
            .navigationTitle(isNew ? "New Provider" : "Edit Provider")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(profile.name.isEmpty || profile.model.isEmpty || profile.baseURL.isEmpty)
                }
            }
        }
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.save(profile)
        if !apiKey.isEmpty { try? KeychainStore.put(apiKey, for: "provider.\(profile.id.uuidString)") }
    }

    private func test() {
        // Save first so the in-memory key can be used by the client.
        save()
        testing = true
        connectionMessage = "Connecting…"
        Task {
            do {
                let text = try await LLMService.request(profile: profile, messages: [
                    LLMMessage(role: "user", content: "Reply with exactly: connection OK")
                ]) { _ in }
                connectionMessage = "Connected: " + String(text.prefix(180))
            } catch { connectionMessage = error.localizedDescription }
            testing = false
        }
    }
}
