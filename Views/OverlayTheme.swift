import SwiftUI

enum OverlayTheme {
    private static var isContainerMode: Bool {
        UserDefaults.standard.string(forKey: "MLV_WorkloadRuntime") == "appleContainer"
    }

    static var background: Color {
        return Color.black
    }

    static var backgroundEdge: Color {
        return Color.black
    }

    static var panel: Color {
        if isContainerMode {
            return Color(red: 0.42, green: 0.70, blue: 0.98).opacity(0.20)
        }
        return Color(red: 0.19, green: 0.19, blue: 0.19).opacity(0.95)
    }

    static var panelStrong: Color {
        if isContainerMode {
            return Color(red: 0.52, green: 0.79, blue: 1.0).opacity(0.28)
        }
        return Color(red: 0.24, green: 0.24, blue: 0.24).opacity(0.96)
    }

    static var border: Color {
        if isContainerMode {
            return Color(red: 0.66, green: 0.86, blue: 1.0).opacity(0.55)
        }
        return Color.white.opacity(0.14)
    }

    static var textPrimary: Color {
        Color.white.opacity(0.92)
    }

    static var textSecondary: Color {
        Color.white.opacity(0.64)
    }

    static var accent: Color {
        if isContainerMode {
            return Color(red: 0.57, green: 0.81, blue: 1.0)
        }
        return Color.white.opacity(0.90)
    }
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
