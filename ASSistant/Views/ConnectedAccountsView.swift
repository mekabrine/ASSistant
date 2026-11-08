import SwiftUI

@MainActor
struct ConnectedAccountsView: View {
    @ObservedObject private var accounts = ConnectedServices.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("googleOAuthClientID") private var googleClientID = ""
    @AppStorage("spotifyOAuthClientID") private var spotifyClientID = ""
    @State private var working: ConnectedServiceKind?
    @State private var output = ""
    @State private var query = ""
    @State private var composeEmail = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Connected services", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Text("Your accounts connect directly to their official OAuth authorization pages. ASSistant stores tokens in the iPhone Keychain, not in chats or iCloud. You can revoke or disconnect either account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Google / Gmail") {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Google Account")
                                .font(.headline)
                            Text(accounts.googleConnected ? "Connected on this device" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if accounts.googleConnected {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        }
                    }
                    TextField("Google OAuth iOS client ID", text: $googleClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("Register an iOS OAuth client in Google Cloud Console. Redirect URI: com.mekabrine.assistant:/oauth2redirect. Configure Gmail API and testing users before signing in. Gmail read permission is a restricted Google OAuth scope and may require verification.")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if accounts.googleConnected {
                        HStack {
                            Button("Check identity") { run { try await accounts.googleIdentity() } }
                            Spacer()
                            Button("Disconnect", role: .destructive) {
                                accounts.disconnect(.google)
                                output = accounts.statusMessage
                            }
                        }
                        TextField("Search Gmail (optional)", text: $query)
                        Button("Search my inbox") {
                            run { try await GmailService.list(query: query) }
                        }
                        Button("Compose Gmail message") { composeEmail = true }
                    } else {
                        Button("Sign in with Google") { connect(.google) }
                            .disabled(working != nil || googleClientID.isEmpty)
                    }
                }

                Section("Spotify") {
                    HStack {
                        Image(systemName: "music.note.list")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spotify")
                                .font(.headline)
                            Text(accounts.spotifyConnected ? "Connected on this device" : "Not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if accounts.spotifyConnected {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                        }
                    }
                    TextField("Spotify Developer Client ID", text: $spotifyClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("Create a Spotify developer app for iOS. Add callback assistantspotify://callback in its redirect configuration. Spotify controls may require Premium and an active playback device.")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if accounts.spotifyConnected {
                        Button("Get Spotify identity") { run { try await accounts.spotifyIdentity() } }
                        Button("Currently playing") { run { try await SpotifyService.nowPlaying() } }
                        Button("My playlists") { run { try await SpotifyService.playlists() } }
                        Button("Disconnect Spotify", role: .destructive) {
                            accounts.disconnect(.spotify)
                            output = accounts.statusMessage
                        }
                    } else {
                        Button("Sign in with Spotify") { connect(.spotify) }
                            .disabled(working != nil || spotifyClientID.isEmpty)
                    }
                }
                if working != nil {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Connecting to " + (working?.title ?? "service") + "…")
                        }
                    }
                }
                if !output.isEmpty {
                    Section("Latest result") {
                        Text(output)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                Section("Account privacy and permissions") {
                    Text("Account data is retrieved only for requests you make or agent actions you allow. Read-only Gmail and Spotify tools can be called during a chat after account connection. Sending mail, altering playback, contacting someone, and launching a Shortcut require explicit confirmation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Account sign-in here does not grant access to Google Drive, Google Photos, or other unrelated APIs. Those services require their own scopes and integrations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connected Accounts")
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $composeEmail) {
                GmailComposeView().environmentObject(accounts)
            }
        }
    }

    private func connect(_ kind: ConnectedServiceKind) {
        working = kind
        output = ""
        Task {
            do {
                try await accounts.connect(kind)
                output = accounts.statusMessage
            } catch {
                output = error.localizedDescription
            }
            working = nil
        }
    }

    private func run(_ operation: @escaping () async throws -> String) {
        Task {
            do {
                output = try await operation()
            } catch {
                output = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct GmailComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var subject = ""
    @State private var message = ""
    @State private var confirm = false
    @State private var inFlight = false
    @State private var result = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("To (email address)", text: $recipient)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Subject", text: $subject)
                TextEditor(text: $message).frame(minHeight: 150)
                Button(inFlight ? "Sending…" : "Review & send via Gmail") {
                    confirm = true
                }
                .disabled(inFlight || recipient.isEmpty || message.isEmpty)
                if !result.isEmpty {
                    Text(result).font(.caption).textSelection(.enabled)
                }
            }
            .navigationTitle("New Gmail")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog("Send this email?", isPresented: $confirm) {
                Button("Send to " + recipient) {
                    inFlight = true
                    Task {
                        do {
                            result = try await GmailService.send(to: recipient, subject: subject, body: message)
                        } catch {
                            result = error.localizedDescription
                        }
                        inFlight = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Subject: \(subject)\n\(String(message.prefix(250)))")
            }
        }
    }
}
