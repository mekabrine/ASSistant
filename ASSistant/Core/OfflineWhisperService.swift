import Foundation
import WhisperKit

/// The same free-on-device WhisperKit approach used by HTMLApp.
/// First use downloads a local model over the internet. No API key and no
/// provider subscription; later transcriptions run on the iPhone.
@MainActor
final class OfflineWhisperService {
    static let shared = OfflineWhisperService()
    private var engine: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    private init() {}

    func transcribe(_ file: URL) async throws -> String {
        let recognizer: WhisperKit
        if let engine {
            recognizer = engine
        } else {
            if loading == nil { loading = Task { try await WhisperKit() } }
            guard let task = loading else { throw TranscriptionError.unavailable }
            do {
                recognizer = try await task.value
                engine = recognizer
                loading = nil
            } catch {
                loading = nil
                throw error
            }
        }
        let results = try await recognizer.transcribe(audioPath: file.path)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.invalidResponse }
        return text
    }
}
