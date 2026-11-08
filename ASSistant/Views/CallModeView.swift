import SwiftUI

/// Foreground, turn-based voice conversation: microphone -> STT -> agent -> TTS.
/// It isn't a phone call or always-on background service. Speech is muted
/// during answer playback; new recording starts only after playback finishes.
@MainActor
struct CallModeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chatID: UUID
    @Binding var agentProgress: String
    let onSend: (String) -> Void

    @StateObject private var whisper = WhisperRecorder()
    @StateObject private var apple = SpeechRecorder()
    @StateObject private var speaker = CallSpeaker()
    @AppStorage("dictationEngine") private var dictationEngine = "offline"
    @State private var connected = false
    @State private var muted = false
    @State private var awaitingAnswer = false
    @State private var busyFinishing = false
    @State private var displayState = "Connecting"
    @State private var lastYouSaid = ""
    @State private var lastAssistantSaid = ""
    @State private var errorText = ""
    @State private var pulse = false
    @State private var lastObservedAnswer: UUID?
    @State private var lastSpokenProgress = ""

    private var profile: ProviderProfile? {
        guard let thread = store.chats.first(where: { $0.id == chatID }) else { return nil }
        return store.provider(for: thread)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [
                Color(red: 0.045, green: 0.075, blue: 0.17),
                Color(red: 0.10, green: 0.10, blue: 0.25),
                Color(red: 0.03, green: 0.13, blue: 0.22)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Label("VOICE SESSION", systemImage: "waveform.circle.fill")
                        .font(.caption).fontWeight(.bold)
                        .tracking(1.8).foregroundStyle(.cyan)
                    Spacer()
                    Button { endCall() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    .tint(.white)
                }
                .padding(.top, 24)

                Spacer()

                ZStack {
                    Circle().stroke(.cyan.opacity(0.15), lineWidth: 1)
                        .frame(width: 244, height: 244)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .opacity(pulse ? 0.25 : 0.8)
                    Circle().stroke(.blue.opacity(0.32), lineWidth: 2)
                        .frame(width: 210, height: 210)
                        .scaleEffect(pulse ? 1.07 : 0.88)
                    Circle()
                        .fill(LinearGradient(colors: [.cyan.opacity(0.60), .indigo.opacity(0.82)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 172, height: 172)
                        .shadow(color: .cyan.opacity(0.4), radius: 35)
                    Image(systemName: speaker.speaking ? "speaker.wave.3.fill" :
                                  (isListening ? "waveform" : "sparkles"))
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.white)
                        .animation(.easeInOut(duration: 0.25), value: speaker.speaking)
                }
                .frame(height: 260)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

                Text(displayState)
                    .font(.title2).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .animation(.easeInOut(duration: 0.25), value: displayState)

                Text(isListening ? "Speak normally. Recording stops after a pause." :
                     awaitingAnswer ? "ASSistant is thinking…" :
                     "A private, foreground voice conversation")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)

                if !lastYouSaid.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YOU SAID").font(.caption2).fontWeight(.bold).foregroundStyle(.cyan)
                        Text(lastYouSaid).foregroundStyle(.white)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                }
                if !lastAssistantSaid.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ASSISTANT").font(.caption2).fontWeight(.bold).foregroundStyle(.cyan)
                        Text(lastAssistantSaid).foregroundStyle(.white)
                            .lineLimit(5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                }

                if !errorText.isEmpty {
                    Text(errorText).font(.caption).foregroundStyle(.orange)
                }

                Spacer()

                HStack(spacing: 24) {
                    Button {
                        muted.toggle()
                        if muted {
                            whisper.cancel()
                            apple.stop()
                            speaker.stop()
                            displayState = "Microphone muted"
                        } else {
                            Task { await beginListening() }
                        }
                    } label: {
                        Label(muted ? "Unmute" : "Mute", systemImage: muted ? "mic.slash.fill" : "mic.fill")
                            .frame(minWidth: 82, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button {
                        if isListening {
                            Task { await finishTurn() }
                        } else if !awaitingAnswer && !speaker.speaking {
                            Task { await beginListening() }
                        } else if speaker.speaking {
                            speaker.stop()
                            Task { await beginListening() }
                        }
                    } label: {
                        Image(systemName: isListening ? "arrow.up.circle.fill" :
                                       speaker.speaking ? "forward.end.fill" : "mic.fill")
                            .font(.system(size: 29))
                            .frame(width: 82, height: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(muted || busyFinishing || (awaitingAnswer && !speaker.speaking))

                    Button(action: endCall) {
                        Label("End", systemImage: "phone.down.fill")
                            .frame(minWidth: 82, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
        }
        .onAppear {
            connected = true
            lastObservedAnswer = store.messages(in: chatID).last(where: { $0.role == "assistant" })?.id
            whisper.autoStopSilence = true
            whisper.onAutoStop = { Task { await finishTurn() } }
            Task { await beginListening() }
        }
        .onChange(of: agentProgress) { value in
            guard connected && awaitingAnswer && !muted,
                  let phrase = VoiceCallProgress.shortPhrase(for: value),
                  phrase != lastSpokenProgress else { return }
            lastSpokenProgress = phrase
            displayState = phrase
            Task {
                await speaker.speak(phrase)
            }
        }
        .onChange(of: store.messages.count) { _ in
            guard connected && awaitingAnswer,
                  let latest = store.messages(in: chatID).last,
                  latest.role == "assistant", latest.id != lastObservedAnswer else { return }
            lastObservedAnswer = latest.id
            awaitingAnswer = false
            lastAssistantSaid = latest.content
            displayState = "ASSistant speaking"
            Task {
                await speaker.speak(VoiceCallProgress.spokenReply(latest.content))
                if connected && !muted { await beginListening() }
            }
        }
        .onDisappear {
            connected = false
            whisper.cancel()
            apple.stop()
            speaker.stop()
        }
    }

    private var isListening: Bool {
        dictationEngine == "apple" ? apple.recording : whisper.isRecording
    }

    private func beginListening() async {
        guard connected && !muted && !awaitingAnswer && !busyFinishing && !isListening else { return }
        do {
            errorText = ""
            displayState = "Listening"
            if dictationEngine == "apple" {
                try await apple.start()
            } else {
                try await whisper.start()
            }
        } catch {
            displayState = "Microphone unavailable"
            errorText = error.localizedDescription
        }
    }

    private func finishTurn() async {
        guard connected && !busyFinishing && isListening else { return }
        busyFinishing = true
        displayState = "Transcribing…"
        do {
            let transcript: String
            if dictationEngine == "apple" {
                apple.stop()
                transcript = apple.transcript
            } else {
                transcript = try await whisper.stopAndTranscribe(profile: profile)
            }
            let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                lastYouSaid = value
                displayState = "ASSistant is thinking"
                awaitingAnswer = true
                onSend(value)
            } else {
                displayState = "Didn't hear anything"
                Task { try? await Task.sleep(nanoseconds: 900_000_000); await beginListening() }
            }
        } catch {
            displayState = "Speech request failed"
            errorText = error.localizedDescription
        }
        busyFinishing = false
    }

    private func endCall() {
        connected = false
        whisper.cancel()
        apple.stop()
        speaker.stop()
        dismiss()
    }
}
