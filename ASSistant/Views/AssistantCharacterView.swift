import SwiftUI

enum AssistantCharacterState: Equatable {
    case idle
    case thinking
    case browsing
    case waitingForUser
    case speaking
    case working

    @MainActor
    static func resolve(status: String, browser: BrowserWorkspace,
                        loading: Bool, callMode: Bool) -> AssistantCharacterState {
        let lower = status.lowercased()
        if browser.awaitingHuman || browser.active.requiresHuman { return .waitingForUser }
        if callMode { return .speaking }
        if lower.contains("browser") || lower.contains("search") ||
           lower.contains("website") || lower.contains("checkout") { return .browsing }
        if lower.contains("thinking") || lower.contains("preparing") { return .thinking }
        if loading { return .working }
        return .idle
    }

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .thinking: return "Thinking"
        case .browsing: return "Browsing"
        case .waitingForUser: return "Needs you"
        case .speaking: return "Talking"
        case .working: return "Working"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "sparkles"
        case .thinking: return "ellipsis"
        case .browsing: return "globe"
        case .waitingForUser: return "hand.raised.fill"
        case .speaking: return "waveform"
        case .working: return "bolt.fill"
        }
    }
}

/// Small animated ASSistant mascot. It reflects real foreground state rather
/// than inventing progress. Status text comes from the agent/browser engine.
struct AssistantCharacterView: View {
    let state: AssistantCharacterState
    let detail: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .overlay(
                        Circle()
                            .stroke(Color.cyan.opacity(0.42), lineWidth: 1)
                    )
                    .frame(width: 46, height: 46)
                    .shadow(color: Color.cyan.opacity(0.18), radius: 8)

                mascot
                    .frame(width: 34, height: 34)
                    .offset(y: state == .thinking && animate ? -2 : 0)
                    .rotationEffect(.degrees(state == .browsing && animate ? 4 : -2))

                Image(systemName: state.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.cyan)
                    .padding(4)
                    .background(.ultraThinMaterial, in: Circle())
                    .offset(x: 17, y: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(state.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(detail.isEmpty ? state.label : detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ASSistant \(state.label). \(detail)")
        .onAppear { updateAnimation() }
        .onChange(of: state) { _ in updateAnimation() }
    }

    private var mascot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.95), Color.blue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 29, height: 27)

            HStack(spacing: 6) {
                Circle().fill(.white).frame(width: 4.5, height: 4.5)
                Circle().fill(.white).frame(width: 4.5, height: 4.5)
            }
            .offset(y: -3)

            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: state == .waitingForUser ? 7 : 10, height: 2.5)
                .offset(y: 6)

            Capsule()
                .fill(Color.cyan)
                .frame(width: 11, height: 3)
                .offset(y: 17)
        }
    }

    private func updateAnimation() {
        guard !reduceMotion, state != .idle, state != .waitingForUser else {
            animate = false
            return
        }
        animate = false
        withAnimation(.easeInOut(duration: state == .browsing ? 0.65 : 0.8)
            .repeatForever(autoreverses: true)) {
            animate = true
        }
    }
}
