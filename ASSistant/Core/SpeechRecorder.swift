import Foundation
import Speech
import AVFoundation

enum SpeechInputError: LocalizedError {
    case unauthorized
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Speech recognition or microphone permission was denied."
        case .unavailable: return "Speech recognition is unavailable for this language or device."
        }
    }
}

@MainActor
final class SpeechRecorder: ObservableObject {
    @Published var transcript = ""
    @Published var recording = false
    private let audioEngine = AVAudioEngine()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async throws {
        guard !recording else { return }
        let speechPermission = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechPermission == .authorized else { throw SpeechInputError.unauthorized }
        let micPermission = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
        guard micPermission else { throw SpeechInputError.unauthorized }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechInputError.unavailable
        }
        transcript = ""
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audio.setActive(true, options: .notifyOthersOnDeactivation)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        speechRequest = request
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            node.removeTap(onBus: 0)
            speechRequest = nil
            try? audio.setActive(false)
            throw error
        }
        recording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { self.stop() }
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        speechRequest?.endAudio()
        task?.cancel()
        task = nil
        speechRequest = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
