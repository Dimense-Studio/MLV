import SwiftUI

enum OverlayTheme {
    static let background = Color.black
    static let backgroundEdge = Color(red: 0.02, green: 0.02, blue: 0.02)
    static let panel = Color.white.opacity(0.08)
    static let panelStrong = Color.white.opacity(0.13)
    static let border = Color.white.opacity(0.10)
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

            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.38)],
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
