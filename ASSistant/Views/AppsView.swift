import SwiftUI
import WebKit

@MainActor
struct AppsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingBuilder = false
    @State private var editingApp: GeneratedApp?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingBuilder = true } label: {
                        Label("Create an HTMLApp with AI", systemImage: "wand.and.stars")
                    }
                }
                Section("Generated applications") {
                    if store.apps.isEmpty {
                        Text("No apps yet. Build a mini-app, review it, publish the HTML, then install it in HTMLApp.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.apps) { app in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.title).font(.headline)
                                    Text("Version \(app.version) · \(app.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button { editingApp = app } label: { Label("Edit", systemImage: "pencil") }
                                    .buttonStyle(.bordered)
                            }
                            if let source = app.sourceURL {
                                Text(source).font(.caption2).lineLimit(2).textSelection(.enabled)
                                Button("Install in HTMLApp") {
                                    Task { try? await HTMLAppBuilder.openHTMLApp(source) }
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Text("Not published yet").font(.caption).foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) { store.delete(app.id, kind: "app") } label: { Text("Delete") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("HTMLApps")
            .sheet(isPresented: $showingBuilder) {
                AppBuilderScreen(initialPrompt: "")
                    .environmentObject(store)
            }
            .sheet(item: $editingApp) { app in
                AppBuilderScreen(initialPrompt: app.prompt, existing: app)
                    .environmentObject(store)
            }
        }
    }
}

@MainActor
struct AppBuilderScreen: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let initialPrompt: String
    let existing: GeneratedApp?
    @State private var prompt: String
    @State private var html: String
    @State private var title: String
    @State private var selectedProviderID: UUID?
    @State private var sourceURL: String?
    @State private var appID: UUID
    @State private var version: Int
    @State private var generating = false
    @State private var publishing = false
    @State private var progress = ""
    @State private var errorText = ""
    @State private var showPreview = false
    @AppStorage("publisherEndpoint") private var publisherEndpoint = ""

    init(initialPrompt: String, existing: GeneratedApp? = nil) {
        self.initialPrompt = initialPrompt
        self.existing = existing
        _prompt = State(initialValue: initialPrompt)
        _html = State(initialValue: existing?.html ?? "")
        _title = State(initialValue: existing?.title ?? "My Mini App")
        _sourceURL = State(initialValue: existing?.sourceURL)
        _appID = State(initialValue: existing?.id ?? UUID())
        _version = State(initialValue: existing?.version ?? 0)
    }

    private var profile: ProviderProfile? {
        store.providers.first(where: { $0.id == selectedProviderID }) ?? store.providers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Describe your app") {
                    TextEditor(text: $prompt).frame(minHeight: 90)
                    Picker("Model", selection: $selectedProviderID) {
                        Text("Default").tag(nil as UUID?)
                        ForEach(store.providers) { provider in
                            Text("\(provider.name) · \(provider.model)").tag(Optional(provider.id))
                        }
                    }
                    Button(generating ? "Generating…" : existing == nil ? "Generate HTML" : "Revise HTML") {
                        generate()
                    }
                    .disabled(generating || publishing || prompt.trimmingCharacters(in: .whitespaces).isEmpty || profile == nil)
                }
                if generating {
                    Section("Generating") {
                        ProgressView()
                        Text(String(progress.suffix(600))).font(.caption).lineLimit(10)
                    }
                }
                if !html.isEmpty {
                    Section("Review and edit HTML") {
                        TextField("App name", text: $title)
                        HStack {
                            Text("\(html.utf8.count) bytes").font(.caption)
                            Spacer()
                            Button("Preview") { showPreview = true }
                            Button("Save") { saveLocal() }
                        }
                        TextEditor(text: $html)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 200)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Button(publishing ? "Uploading…" : "Upload HTML & get install link") { publish() }
                            .disabled(generating || publishing)
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let sourceURL {
                    Section("Published HTML") {
                        Text(sourceURL).font(.footnote).textSelection(.enabled)
                        Button("Open HTMLApp installation") { install() }
                            .buttonStyle(.borderedProminent)
                        Text("HTMLApp opens an import draft. You choose whether to save it. A public/unlisted URL is readable by anyone with the link.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                if !errorText.isEmpty {
                    Section { Text(errorText).foregroundColor(.red) }
                }
            }
            .navigationTitle("Build HTMLApp")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: html) { _ in sourceURL = nil }
            .sheet(isPresented: $showPreview) {
                NavigationStack {
                    HTMLPreview(html: html)
                        .navigationTitle("App Preview")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPreview = false } } }
                }
            }
        }
    }

    private func currentApp() -> GeneratedApp {
        GeneratedApp(id: appID, title: title.isEmpty ? "Mini App" : title, prompt: prompt,
                     html: html, sourceURL: sourceURL, createdAt: existing?.createdAt ?? Date(),
                     updatedAt: .now, version: max(1, version))
    }

    private func saveLocal() {
        do {
            html = try HTMLAppBuilder.normalizedHTML(html)
            store.save(currentApp())
            errorText = ""
        } catch { errorText = error.localizedDescription }
    }

    private func generate() {
        guard let profile else { return }
        generating = true
        errorText = ""
        progress = ""
        Task {
            do {
                let generated = try await HTMLAppBuilder.generate(
                    request: prompt, profile: profile, existing: html.isEmpty ? existing : currentApp()
                ) { part in progress += part }
                html = generated.html
                title = generated.title
                version = generated.version
                sourceURL = nil
                saveLocal()
            } catch { errorText = error.localizedDescription }
            generating = false
        }
    }

    private func publish() {
        publishing = true
        errorText = ""
        Task {
            do {
                let validHTML = try HTMLAppBuilder.normalizedHTML(html)
                html = validHTML
                let app = currentApp()
                let uploaded = try await HTMLPublisher.publish(app)
                sourceURL = uploaded
                store.save(currentApp())
            } catch { errorText = error.localizedDescription }
            publishing = false
        }
    }

    private func install() {
        guard let sourceURL else { return }
        Task {
            do { try await HTMLAppBuilder.openHTMLApp(sourceURL) }
            catch { errorText = error.localizedDescription }
        }
    }
}

struct HTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Preview has no HTMLApp native bridge or credentials.
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            uiView.loadHTMLString(html, baseURL: nil)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var lastHTML = ""
    }
}
