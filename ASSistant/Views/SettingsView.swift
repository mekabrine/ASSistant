import SwiftUI
import CoreLocation
import CloudKit

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var createProvider = false
    @State private var showAgents = false
    @State private var showAccounts = false
    @State private var showDeviceActions = false
    @State private var showPurchases = false
    @State private var confirmBrowserReset = false
    @State private var editingProvider: ProviderProfile?
    @State private var gistToken = ""
    @State private var publisherToken = ""
    @State private var speechToken = ""
    @State private var testResult = ""
    @State private var permissionResult = ""
    @AppStorage("publisherEndpoint") private var publisherEndpoint = ""
    @AppStorage("htmlUploadService") private var htmlUploadService = "paste"
    @AppStorage("dictationEngine") private var dictationEngine = "offline"
    @AppStorage("sttEndpoint") private var sttEndpoint = ""
    @AppStorage("sttModel") private var sttModel = "gpt-transcribe"
    @AppStorage("sttRequireKey") private var sttRequireKey = true
    @AppStorage("cloudSyncEnabled") private var cloudSyncEnabled = false
    @AppStorage("autoSummaryEnabled") private var autoSummaryEnabled = true
    @AppStorage("agentMaxSteps") private var agentMaxSteps = 18
    @AppStorage("shoppingAutonomyLevel") private var shoppingAutonomyLevel = 1
    @AppStorage("shoppingOrderCap") private var shoppingOrderCap = 250.0
    @AppStorage("shoppingMonthlyCap") private var shoppingMonthlyCap = 500.0
    @AppStorage("chatTitleProviderID") private var chatTitleProviderID = ""
    @AppStorage("chatTitleModel") private var chatTitleModel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected apps and accounts") {
                    Button { showAccounts = true } label: {
                        Label("Connect Google / Gmail and Spotify", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Button { showDeviceActions = true } label: {
                        Label("Phone, Messages, Shortcuts & Contacts", systemImage: "iphone")
                    }
                    Text("Connect external services with OAuth. Sending messages, calling, and account modifications are confirmation-gated.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent personalities and control") {
                    Button {
                        showAgents = true
                    } label: {
                        Label("Manage agents and tool permissions", systemImage: "person.2.fill")
                    }
                    Text("Choose custom agent instructions, model routing, and which native/web tools are enabled. Device writes always require approval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Browser privacy") {
                    Label("Website sessions persist across chats", systemImage: "globe.americas.fill")
                    Text("WebKit retains logins in ASSistant's own website data store. They are separate from Safari and from Google/Spotify OAuth tokens. An agent with web access can read visible page text from signed-in sites. Input values, passwords, cookies and security codes are not intentionally included in model context.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        confirmBrowserReset = true
                    } label: {
                        Label("Erase all browser sign-ins and website data", systemImage: "trash")
                    }
                }
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
                        .onChange(of: cloudSyncEnabled) { enabled in
                            if enabled {
                                UserDefaults.standard.set(false, forKey: "assistant.cloudRecoveryMode")
                                UserDefaults.standard.set(false, forKey: "assistant.databaseLaunchInProgress")
                            }
                        }
                    Text(store.syncStatus).font(.caption)
                    if UserDefaults.standard.bool(forKey: "assistant.cloudRecoveryMode") {
                        Text("Recovery mode is active after an interrupted/failed iCloud database startup. Your local data is preserved.")
                            .font(.footnote).foregroundColor(.orange)
                        Button("Retry iCloud after next restart") {
                            UserDefaults.standard.set(false, forKey: "assistant.cloudRecoveryMode")
                            UserDefaults.standard.set(false, forKey: "assistant.databaseLaunchInProgress")
                            cloudSyncEnabled = true
                            testResult = "iCloud retry is armed. Close and reopen ASSistant."
                        }
                    }
                    Text("Local storage is the safe default for unsigned or sideloaded builds. Enabling iCloud takes effect after restarting. CloudKit requires a valid signing profile, registered container and Apple account; keys remain local to each device.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section("Automatic chat names") {
                    Picker("Title-generation provider", selection: $chatTitleProviderID) {
                        Text("Current chat provider").tag("")
                        ForEach(store.providers) { provider in
                            Text(provider.name).tag(provider.id.uuidString)
                        }
                    }
                    TextField("Small model ID (optional)", text: $chatTitleModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("Names are refreshed when a chat begins and approximately every five messages, using up to the last 50 turns. Pick a cheap/small model supported by your provider; title generation makes additional API requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent autonomy and shopping") {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Label("Shopping autonomy", systemImage: "slider.horizontal.3")
                                .font(.headline)
                            Spacer()
                            Text("\(shoppingAutonomyLevel) / 4")
                                .font(.subheadline).monospacedDigit()
                        }
                        Slider(value: Binding(
                            get: { Double(shoppingAutonomyLevel) },
                            set: { shoppingAutonomyLevel = Int($0.rounded()) }
                        ), in: 0...4, step: 1)
                        Text(ShoppingPolicy.levelNames[max(0, min(4, shoppingAutonomyLevel))])
                            .font(.subheadline).fontWeight(.semibold)
                        Text("0: browse only · 1: choose colors/sizes · 2: cart · 3: checkout preparation · 4: submit orders after approving the exact total. Final purchases always require confirmation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Maximum single order")
                        Spacer()
                        TextField("USD", value: $shoppingOrderCap, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Monthly spending limit")
                        Spacer()
                        TextField("USD", value: $shoppingMonthlyCap, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    Button { showPurchases = true } label: {
                        HStack {
                            Label("Purchases and order history", systemImage: "bag.fill")
                            Spacer()
                            Text("\(store.purchases.count)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Amounts are USD spending caps. Unverified submissions also count toward your monthly limit until resolved. The agent never receives payment details or authorization to bypass verification.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Maximum agent tool steps: \(agentMaxSteps)", value: $agentMaxSteps, in: 3...40)
                    Text("More steps help the AI finish its last requested browser action, but can increase model API usage. A goal check prevents unsupported steps from being silently reported as done.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Context and memory") {
                    Toggle("Auto-summarize longer chats (extra AI calls)", isOn: $autoSummaryEnabled)
                    Text("Memories are selectively retrieved. Sensitive memories are not auto-included. Full chat history is stored for search and can sync.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section {
                    Picker("Dictation engine", selection: $dictationEngine) {
                        Text("Free on-device Whisper").tag("offline")
                        Text("Cloud Whisper API").tag("whisper")
                        Text("Apple Speech").tag("apple")
                    }
                    .pickerStyle(.segmented)
                    if dictationEngine == "offline" {
                        Text("WhisperKit runs speech recognition on your device without a transcription API key. A model is downloaded the first time you use it (internet and free storage required). Transcribed audio is not uploaded to a speech API.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    if dictationEngine == "whisper" {
                        TextField("Transcription URL (optional if using chat provider)", text: $sttEndpoint)
                            .keyboardType(.URL).textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        TextField("Speech model", text: $sttModel)
                            .autocorrectionDisabled(true).textInputAutocapitalization(.never)
                        Toggle("Require API key", isOn: $sttRequireKey)
                        SecureField("Dedicated transcription API key", text: $speechToken)
                            .autocorrectionDisabled(true).textInputAutocapitalization(.never)
                        Button("Save speech API key") {
                            do {
                                try KeychainStore.put(speechToken, for: "stt.apiKey")
                                speechToken = ""
                                testResult = "Speech API key saved on this device."
                            } catch { testResult = error.localizedDescription }
                        }
                        .disabled(speechToken.isEmpty)
                        Button("Use chat provider key instead") {
                            KeychainStore.delete("stt.apiKey")
                            testResult = "Dedicated speech key cleared; using chat provider's local Keychain key."
                        }
                        Text("Leave URL blank to use the selected chat provider's /audio/transcriptions route. Example models: gpt-transcribe, whisper-1, whisper-large-v3-turbo. Use a compatible endpoint. Recorded audio is sent to your chosen provider only after you stop recording.")
                            .font(.footnote).foregroundColor(.secondary)
                    } else if dictationEngine == "apple" {
                        Text("Apple Speech recognition may not work on every device. Cloud Whisper and local WhisperKit do not depend on the Apple keyboard dictation service.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    Text("Call mode uses microphone → transcription → agent → spoken reply. It runs only while the app is open.")
                        .font(.footnote).foregroundColor(.secondary)
                } header: {
                    Label("Voice and call mode", systemImage: "waveform")
                }
                Section("HTML publishing") {
                    Picker("Public hosting service", selection: $htmlUploadService) {
                        Text("No key · paste.rs").tag("paste")
                        Text("No key · Beacon (24-hour link)").tag("beacon")
                        Text("GitHub Gist (token)").tag("gist")
                        Text("My HTTPS upload server").tag("custom")
                    }
                    Text("Publishing is optional until you install an HTMLApp. These URLs are public to anyone who knows them. Never publish tokens or personal data. Paste.rs is rate-limited; anonymous Beacon files expire after roughly 24 hours.")
                        .font(.footnote).foregroundColor(.secondary)
                    if htmlUploadService == "gist" {
                        SecureField("GitHub token (gist permission)", text: $gistToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        Button("Save Gist token") {
                            do {
                                try KeychainStore.put(gistToken, for: "github.publisher")
                                gistToken = ""
                                testResult = "Gist token saved locally."
                            } catch { testResult = error.localizedDescription }
                        }.disabled(gistToken.isEmpty)
                    }
                    if htmlUploadService == "custom" {
                        TextField("HTTPS publishing endpoint", text: $publisherEndpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true).keyboardType(.URL)
                        SecureField("Custom endpoint bearer token (optional)", text: $publisherToken)
                        Button("Save custom endpoint token") {
                            do {
                                try KeychainStore.put(publisherToken, for: "publisher.customToken")
                                publisherToken = ""
                                testResult = "Custom endpoint token saved locally."
                            } catch { testResult = error.localizedDescription }
                        }.disabled(publisherToken.isEmpty)
                        Text("Custom contract: POST text/html; reply with JSON containing the public HTTPS url.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
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
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Settings")
            .confirmationDialog("Erase saved browser sessions?", isPresented: $confirmBrowserReset,
                                titleVisibility: .visible) {
                Button("Erase saved website data", role: .destructive) {
                    Task {
                        await BrowserWorkspace.shared.clearBrowserLogins()
                        testResult = "Website cookies and browser storage were cleared."
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs out websites in ASSistant's browser tabs, but does not revoke separate Google/Spotify OAuth connections.")
            }
            .sheet(isPresented: $showAgents) {
                AgentsView().environmentObject(store)
            }
            .sheet(isPresented: $showAccounts) {
                ConnectedAccountsView().environmentObject(store)
            }
            .sheet(isPresented: $showDeviceActions) {
                DeviceActionsView().environmentObject(store)
            }
            .sheet(isPresented: $showPurchases) {
                PurchaseHistoryView().environmentObject(store)
            }
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
    @State private var discoveredModels: [String] = []

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
                    Button("Discover available models") { discover() }
                        .disabled(testing)
                    if !discoveredModels.isEmpty {
                        Picker("Choose discovered model", selection: $profile.model) {
                            ForEach(discoveredModels, id: \.self) { id in Text(id).tag(id) }
                        }
                    }
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

    private func discover() {
        save()
        testing = true
        Task {
            do {
                discoveredModels = try await LLMService.discoverModels(profile: profile)
                connectionMessage = "Found \(discoveredModels.count) models."
                if profile.model.isEmpty, let first = discoveredModels.first { profile.model = first }
            } catch { connectionMessage = error.localizedDescription }
            testing = false
        }
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
