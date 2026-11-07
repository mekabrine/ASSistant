import Foundation
import AVFoundation
import Combine

enum TranscriptionError: LocalizedError {
    case permission, noRecording, badEndpoint, keyRequired, tooLarge, invalidResponse, unavailable
    var errorDescription: String? {
        switch self {
        case .permission: return "Microphone access is required. Enable it in iOS Settings."
        case .noRecording: return "No audio recording is available."
        case .badEndpoint: return "Configure a valid HTTPS transcription URL in Settings → Voice."
        case .keyRequired: return "The selected Whisper API needs a key. Configure a speech key or a provider key."
        case .tooLarge: return "Audio exceeds the 25 MB upload limit."
        case .invalidResponse: return "Speech server did not return recognized text."
        case .unavailable: return "The microphone or speech service is unavailable."
        }
    }
}

enum TranscriptionAPI {
    /// Standard OpenAI-compatible multipart transcription, usable with Groq,
    /// OpenAI, hosted Whisper services and many self-hosted implementations.
    static func transcribe(_ file: URL, profile: ProviderProfile?) async throws -> String {
        let configured = (UserDefaults.standard.string(forKey: "sttEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: URL
        if !configured.isEmpty, let parsed = URL(string: configured) {
            endpoint = parsed
        } else if let profile {
            let root = try LLMService.baseURL(profile.baseURL)
            endpoint = root.appendingPathComponent("audio/transcriptions")
        } else {
            throw TranscriptionError.badEndpoint
        }
        guard endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil else {
            throw TranscriptionError.badEndpoint
        }
        let key = KeychainStore.get("stt.apiKey")
            ?? profile.flatMap { KeychainStore.get("provider.\($0.id.uuidString)") }
        let requireKey = UserDefaults.standard.object(forKey: "sttRequireKey") as? Bool ?? true
        if requireKey && (key?.isEmpty ?? true) { throw TranscriptionError.keyRequired }

        let data = try Data(contentsOf: file)
        guard data.count > 100 else { throw TranscriptionError.noRecording }
        guard data.count <= 25_000_000 else { throw TranscriptionError.tooLarge }
        let model = UserDefaults.standard.string(forKey: "sttModel")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-transcribe"

        let boundary = "ASSistant-" + UUID().uuidString
        var body = Data()
        func appendText(_ value: String) { body.append(Data(value.utf8)) }
        appendText("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        appendText("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        appendText("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        body.append(data)
        appendText("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (result, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        guard (200...299).contains(status.statusCode) else {
            throw AIRequestError.http(status.statusCode,
                                      String(decoding: result.prefix(700), as: UTF8.self))
        }
        if let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
           let text = json["text"] as? String, !text.isEmpty {
            return text
        }
        if let plain = String(data: result, encoding: .utf8),
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw TranscriptionError.invalidResponse
    }
}

/// Handles microphone recording independent of Apple keyboard dictation.
/// The audio is sent only when the user stops recording (or a call auto-stop).
@MainActor
final class WhisperRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var elapsed: TimeInterval = 0
    @Published var voicePower: Double = 0
    @Published var lastError = ""
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var startedAt: Date?
    private var silentSince: Date?
    private var heardSpeech = false
    var autoStopSilence = false
    var onAutoStop: (() -> Void)?

    func start() async throws {
        guard !isRecording && !isTranscribing else { return }
        let permitted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard permitted else { throw TranscriptionError.permission }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default,
                              options: [.defaultToSpeaker, .allowBluetooth])
        try audio.setActive(true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "assistant-voice-" + UUID().uuidString + ".m4a"
        )
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let voice = try AVAudioRecorder(url: file, settings: settings)
        voice.isMeteringEnabled = true
        guard voice.record(forDuration: 110) else { throw TranscriptionError.unavailable }
        recorder = voice
        startedAt = Date()
        silentSince = nil
        heardSpeech = false
        isRecording = true
        elapsed = 0
        lastError = ""
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    private func updateMeter() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        voicePower = max(0, min(1, (decibels + 55) / 50))
        elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if voicePower > 0.15 { heardSpeech = true }
        guard autoStopSilence && heardSpeech && elapsed > 2.0 else { return }
        if voicePower < 0.12 {
            if silentSince == nil { silentSince = Date() }
            if let silentSince, Date().timeIntervalSince(silentSince) > 1.7 {
                self.silentSince = nil
                onAutoStop?()
            }
        } else {
            silentSince = nil
        }
    }

    func stopAndTranscribe(profile: ProviderProfile?) async throws -> String {
        guard isRecording, let recorder else { throw TranscriptionError.noRecording }
        isRecording = false
        meter?.invalidate()
        meter = nil
        recorder.stop()
        self.recorder = nil
        let file = recorder.url
        isTranscribing = true
        defer {
            isTranscribing = false
            try? FileManager.default.removeItem(at: file)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return try await TranscriptionAPI.transcribe(file, profile: profile)
    }

    func cancel() {
        meter?.invalidate()
        meter = nil
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        isRecording = false
        isTranscribing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Speak and await completion, so call mode can listen again *after* playback.
@MainActor
final class CallSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    let synthesizer = AVSpeechSynthesizer()
    private var finish: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: String(text.prefix(8000)))
        utterance.rate = 0.49
        speaking = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finish = c
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        if let finish { self.finish = nil; finish.resume() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        complete()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        complete()
    }

    private func complete() {
        speaking = false
        if let finish { self.finish = nil; finish.resume() }
    }
}
