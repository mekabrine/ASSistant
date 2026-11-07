import SwiftUI

/// Small, reusable visual language that runs on iOS 16.
/// Liquid Glass-like materials are optional visual treatment; no iOS 26 API
/// is called without availability checks.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var mode
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemBackground)
                LinearGradient(colors: [
                    Color.indigo.opacity(mode == .dark ? 0.17 : 0.065),
                    Color.cyan.opacity(mode == .dark ? 0.08 : 0.03),
                    Color(uiColor: .systemBackground)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
                if !reduceTransparency {
                    Circle()
                        .fill(Color.indigo.opacity(mode == .dark ? 0.18 : 0.12))
                        .frame(width: geometry.size.width * 0.96)
                        .blur(radius: 90)
                        .position(x: geometry.size.width + 10, y: 60)
                    Circle()
                        .fill(Color.cyan.opacity(mode == .dark ? 0.12 : 0.10))
                        .frame(width: geometry.size.width * 0.85)
                        .blur(radius: 100)
                        .position(x: 20, y: geometry.size.height * 0.9)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct AssistantOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glimmer = false
    var size: CGFloat = 84

    var body: some View {
        ZStack {
            Circle()
                .fill(.cyan.opacity(0.2))
                .frame(width: size * 1.55, height: size * 1.55)
                .blur(radius: size * 0.20)
                .scaleEffect(glimmer ? 1.1 : 0.88)
            Circle()
                .fill(LinearGradient(colors: [
                    Color(red: 0.15, green: 0.77, blue: 0.99),
                    .blue, .indigo
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .shadow(color: .indigo.opacity(0.35), radius: 17, y: 6)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.35, weight: .medium))
                .foregroundStyle(.white)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                glimmer = true
            }
        }
        .accessibilityHidden(true)
    }
}

struct TypingPulse: View {
    @State private var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.cyan)
                    .frame(width: 7, height: 7)
                    .offset(y: active && !reduceMotion ? -3 : 3)
                    .animation(.easeInOut(duration: 0.55)
                        .repeatForever(autoreverses: true).delay(Double(index) * 0.13),
                        value: active)
            }
        }
        .frame(height: 19)
        .onAppear { active = true }
        .onDisappear { active = false }
        .accessibilityLabel("ASSistant is responding")
    }
}

struct SoftActionButton: View {
    let text: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(.cyan)
                Text(text).font(.subheadline).fontWeight(.medium)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.cyan.opacity(0.17)))
        }
        .buttonStyle(.plain)
    }
}
