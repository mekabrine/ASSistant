import Foundation

enum SpotifyService {
    static func searchTracks(_ query: String) async throws -> String {
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        guard !text.isEmpty else { throw ConnectedServicesError.invalidInput("Spotify search query") }
        let (data, _) = try await ConnectedServices.shared.fetch(
            .spotify, path: "/v1/search",
            query: [
                URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "limit", value: "10")
            ]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any] else {
            throw ConnectedServicesError.invalidServerResponse
        }
        let items = tracks["items"] as? [[String: Any]] ?? []
        let lines = items.compactMap { row -> String? in
            guard let title = row["name"] as? String else { return nil }
            let artists = (row["artists"] as? [[String: Any]] ?? []).compactMap {
                $0["name"] as? String
            }.joined(separator: ", ")
            let album = (row["album"] as? [String: Any])?["name"] as? String ?? ""
            let uri = row["uri"] as? String ?? ""
            let url = (row["external_urls"] as? [String: String])?["spotify"] ?? ""
            return "\(title) — \(artists) (album: \(album)); URI \(uri); \(url)"
        }
        return lines.isEmpty ? "No Spotify tracks matched \(text)." : lines.joined(separator: "\n")
    }

    static func nowPlaying() async throws -> String {
        let (data, code) = try await ConnectedServices.shared.fetch(
            .spotify, path: "/v1/me/player/currently-playing"
        )
        if code == 204 || data.isEmpty { return "Nothing currently playing." }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No current Spotify playback information."
        }
        let item = json["item"] as? [String: Any] ?? [:]
        let name = item["name"] as? String ?? "Unknown track"
        let artists = (item["artists"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }.joined(separator: ", ")
        let playing = json["is_playing"] as? Bool ?? false
        let url = (item["external_urls"] as? [String: String])?["spotify"] ?? ""
        return "\(playing ? "Playing" : "Paused"): \(name) — \(artists)\n\(url)"
    }

    static func playlists() async throws -> String {
        let (data, _) = try await ConnectedServices.shared.fetch(
            .spotify, path: "/v1/me/playlists",
            query: [URLQueryItem(name: "limit", value: "15")]
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectedServicesError.invalidServerResponse
        }
        let items = json["items"] as? [[String: Any]] ?? []
        let lines = items.compactMap { item -> String? in
            guard let name = item["name"] as? String else { return nil }
            let url = (item["external_urls"] as? [String: String])?["spotify"] ?? ""
            return "\(name): \(url)"
        }
        return lines.isEmpty ? "No playlists returned." : lines.joined(separator: "\n")
    }

    static func playerAction(_ name: String, trackURI: String? = nil) async throws -> String {
        let path: String
        let method: String
        var json: [String: Any]?
        switch name {
        case "spotify_play":
            path = "/v1/me/player/play"
            method = "PUT"
            if let trackURI, !trackURI.isEmpty {
                guard trackURI.range(of: "^spotify:track:[A-Za-z0-9]+$",
                                     options: .regularExpression) != nil else {
                    throw ConnectedServicesError.invalidInput("Spotify track URI")
                }
                json = ["uris": [trackURI]]
            }
        case "spotify_pause":
            path = "/v1/me/player/pause"
            method = "PUT"
        case "spotify_next":
            path = "/v1/me/player/next"
            method = "POST"
        case "spotify_previous":
            path = "/v1/me/player/previous"
            method = "POST"
        default:
            throw ConnectedServicesError.invalidInput(name)
        }
        _ = try await ConnectedServices.shared.fetch(
            .spotify, path: path, method: method, json: json
        )
        return "Spotify accepted \(name.replacingOccurrences(of: "spotify_", with: "")) request. Playback changes may require Spotify Premium and an available active device."
    }
}
