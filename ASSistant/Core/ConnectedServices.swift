import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import Combine

enum ConnectedServiceKind: String, CaseIterable, Identifiable {
    case google
    case spotify

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var clientIDKey: String { rawValue + "OAuthClientID" }
    var callback: String {
        switch self {
        // Google iOS OAuth client must be configured to accept this exact
        // reversed-domain app-owned scheme. Use a verified Google client ID.
        case .google: return "com.mekabrine.assistant:/oauth2redirect"
        // Spotify requires its own unique login-only redirect scheme.
        case .spotify: return "assistantspotify://callback"
        }
    }
    var callbackScheme: String {
        switch self {
        case .google: return "com.mekabrine.assistant"
        case .spotify: return "assistantspotify"
        }
    }
    var authorizeURL: String {
        switch self {
        case .google: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .spotify: return "https://accounts.spotify.com/authorize"
        }
    }
    var tokenURL: String {
        switch self {
        case .google: return "https://oauth2.googleapis.com/token"
        case .spotify: return "https://accounts.spotify.com/api/token"
        }
    }
    var scopes: String {
        switch self {
        case .google:
            // gmail.readonly is a restricted scope; Google may block an
            // unverified production OAuth app until its review is complete.
            return "openid email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"
        case .spotify:
            return "user-read-private user-read-email user-read-playback-state user-read-currently-playing user-modify-playback-state playlist-read-private user-library-read"
        }
    }
}

struct ConnectedAccountTokens: Codable {
    var access: String
    var refresh: String?
    var expiresAt: Date
    var scope: String
}

enum ConnectedServicesError: LocalizedError {
    case configureClient(String)
    case authorizationCancelled
    case mismatchedState
    case missingCode
    case notConnected(String)
    case invalidServerResponse
    case invalidInput(String)
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .configureClient(let name):
            return "Configure the \(name) OAuth client ID in Settings → Connected accounts first."
        case .authorizationCancelled: return "The account sign-in was cancelled."
        case .mismatchedState: return "The sign-in response could not be verified."
        case .missingCode: return "No authorization code was returned."
        case .notConnected(let name): return "\(name) isn't connected. Use Settings → Connected accounts."
        case .invalidServerResponse: return "The account provider returned an unexpected response."
        case .invalidInput(let value): return "Invalid account action: " + value
        case .accessDenied(let value): return "The provider rejected the request: " + value
        }
    }
}

/// Native browser OAuth with PKCE, per-service tokens in device-only Keychain.
/// Client IDs (public identifiers) are user-configured. No embedded client secret.
@MainActor
final class ConnectedServices: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = ConnectedServices()
    @Published private(set) var googleConnected = false
    @Published private(set) var spotifyConnected = false
    @Published var statusMessage = ""
    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        refreshConnectionState()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
            ?? ASPresentationAnchor()
    }

    func refreshConnectionState() {
        googleConnected = Self.readToken(.google) != nil
        spotifyConnected = Self.readToken(.spotify) != nil
    }

    func connected(_ kind: ConnectedServiceKind) -> Bool {
        switch kind {
        case .google: return googleConnected
        case .spotify: return spotifyConnected
        }
    }

    static func clientID(_ kind: ConnectedServiceKind) -> String? {
        let value = (UserDefaults.standard.string(forKey: kind.clientIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func key(_ kind: ConnectedServiceKind) -> String {
        "account.oauth." + kind.rawValue
    }

    private static func readToken(_ kind: ConnectedServiceKind) -> ConnectedAccountTokens? {
        guard let text = KeychainStore.get(key(kind)),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ConnectedAccountTokens.self, from: data)
    }

    private static func saveToken(_ token: ConnectedAccountTokens, for kind: ConnectedServiceKind) throws {
        let data = try JSONEncoder().encode(token)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ConnectedServicesError.invalidServerResponse
        }
        try KeychainStore.put(value, for: key(kind))
    }

    func disconnect(_ kind: ConnectedServiceKind) {
        KeychainStore.delete(Self.key(kind))
        refreshConnectionState()
        statusMessage = "\(kind.title) disconnected locally. Revoke access separately in your \(kind.title) account security settings."
    }

    private static func randomValue() -> String {
        let data = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(data).base64URLEncodedString()
    }

    static func pkceChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    func connect(_ kind: ConnectedServiceKind) async throws {
        guard let clientID = Self.clientID(kind) else {
            throw ConnectedServicesError.configureClient(kind.title)
        }
        guard authSession == nil else { throw ConnectedServicesError.invalidInput("sign-in already running") }
        defer { authSession = nil }
        let verifier = Self.randomValue()
        let state = Self.randomValue()
        var url = URLComponents(string: kind.authorizeURL)!
        var parameters = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: kind.callback),
            URLQueryItem(name: "scope", value: kind.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if kind == .google {
            parameters += [URLQueryItem(name: "access_type", value: "offline"),
                           URLQueryItem(name: "prompt", value: "consent")]
        }
        url.queryItems = parameters
        guard let requestURL = url.url else { throw ConnectedServicesError.invalidServerResponse }
        statusMessage = "Opening \(kind.title) sign-in…"

        let callback: URL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: requestURL, callbackURLScheme: kind.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: ConnectedServicesError.authorizationCancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                self.authSession = nil
                continuation.resume(throwing: ConnectedServicesError.authorizationCancelled)
            }
        }
        let callbackParts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        var fields: [String: String] = [:]
        for item in callbackParts?.queryItems ?? [] {
            // Reject duplicate state/code parameters instead of crashing
            // from Dictionary(uniqueKeysWithValues:) on a malicious redirect.
            guard fields[item.name] == nil else { throw ConnectedServicesError.mismatchedState }
            fields[item.name] = item.value ?? ""
        }
        guard callback.scheme?.lowercased() == kind.callbackScheme,
              fields["state"] == state else { throw ConnectedServicesError.mismatchedState }
        if let error = fields["error"] {
            throw ConnectedServicesError.accessDenied(error)
        }
        guard let code = fields["code"], !code.isEmpty else {
            throw ConnectedServicesError.missingCode
        }
        let token = try await tokenExchange(kind, fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": kind.callback,
            "code_verifier": verifier,
            "client_id": clientID
        ], previousRefresh: nil)
        try Self.saveToken(token, for: kind)
        refreshConnectionState()
        statusMessage = "\(kind.title) connected. Tokens are stored only on this device."
    }

    private func tokenExchange(
        _ kind: ConnectedServiceKind,
        fields: [String: String],
        previousRefresh: String?
    ) async throws -> ConnectedAccountTokens {
        var request = URLRequest(url: URL(string: kind.tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = fields.sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectedServicesError.invalidServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ConnectedServicesError.accessDenied(
                "HTTP \(http.statusCode): " + String(decoding: data.prefix(500), as: UTF8.self)
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw ConnectedServicesError.invalidServerResponse
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return ConnectedAccountTokens(
            access: access,
            refresh: json["refresh_token"] as? String ?? previousRefresh,
            expiresAt: Date().addingTimeInterval(max(30, expires)),
            scope: json["scope"] as? String ?? kind.scopes
        )
    }

    private func validAccess(_ kind: ConnectedServiceKind) async throws -> String {
        guard var token = Self.readToken(kind) else {
            throw ConnectedServicesError.notConnected(kind.title)
        }
        if token.expiresAt.timeIntervalSinceNow > 90 { return token.access }
        guard let refresh = token.refresh, let clientID = Self.clientID(kind) else {
            throw ConnectedServicesError.notConnected(kind.title + " (sign in again)")
        }
        token = try await tokenExchange(kind, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID
        ], previousRefresh: refresh)
        try Self.saveToken(token, for: kind)
        return token.access
    }

    /// All destinations are selected internally and are never model-supplied URLs.
    func fetch(
        _ kind: ConnectedServiceKind,
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        json: [String: Any]? = nil,
        body: Data? = nil
    ) async throws -> (Data, Int) {
        guard path.hasPrefix("/") && !path.hasPrefix("//") else {
            throw ConnectedServicesError.invalidInput("invalid service API path")
        }
        let origin = kind == .google ? "https://gmail.googleapis.com" : "https://api.spotify.com"
        guard var components = URLComponents(string: origin + path) else {
            throw ConnectedServicesError.invalidServerResponse
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url,
              url.host == (kind == .google ? "gmail.googleapis.com" : "api.spotify.com") else {
            throw ConnectedServicesError.invalidServerResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer " + (try await validAccess(kind)), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else {
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectedServicesError.invalidServerResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ConnectedServicesError.accessDenied(
                "HTTP \(http.statusCode) from \(kind.title): " +
                String(decoding: data.prefix(350), as: UTF8.self)
            )
        }
        return (data, http.statusCode)
    }

    func googleIdentity() async throws -> String {
        let token = try await validAccess(.google)
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectedServicesError.invalidServerResponse
        }
        return (json["email"] as? String) ?? "Google connected"
    }

    func spotifyIdentity() async throws -> String {
        let (data, _) = try await fetch(.spotify, path: "/v1/me")
        let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["display_name"] as? String ?? json?["id"] as? String ?? "Spotify connected"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
