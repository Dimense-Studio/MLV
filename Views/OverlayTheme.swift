import SwiftUI

enum OverlayTheme {
    static let background = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let backgroundEdge = Color(red: 0.12, green: 0.14, blue: 0.18)
    static let panel = Color.white.opacity(0.035)
    static let panelStrong = Color.white.opacity(0.06)
    static let border = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.64)
    static let accent = Color.white.opacity(0.90)
}

struct OverlayCanvasBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [OverlayTheme.background, OverlayTheme.backgroundEdge],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                center: .topLeading,
                startRadius: 24,
                endRadius: 720
            )

            RadialGradient(
                colors: [Color(red: 0.30, green: 0.40, blue: 0.52).opacity(0.16), Color.clear],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 900
            )

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct OverlayPanelModifier: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(OverlayTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(OverlayTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func overlayPanel(radius: CGFloat = 20) -> some View {
        modifier(OverlayPanelModifier(radius: radius))
    }
}
