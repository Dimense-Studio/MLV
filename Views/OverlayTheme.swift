import SwiftUI

enum OverlayTheme {
    static var isContainerMode: Bool {
        UserDefaults.standard.string(forKey: "MLV_WorkloadRuntime") == "appleContainer"
    }

    static var background: Color { Color.black }

    static var backgroundEdge: Color {
        return background
    }

    // Light glass tint for all cards
    static var panel: Color { Color.white.opacity(0.08) }

    // Slightly stronger glass for emphasized blocks
    static var panelStrong: Color { Color.white.opacity(0.12) }

    static var border: Color { Color.white.opacity(0.18) }

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
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSince(start)
                
                // Base background
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(OverlayTheme.background))
                
                // Liquid blobs
                let blobCount = 4
                for i in 0..<blobCount {
                    let t = time * 0.4 + Double(i) * 2.0
                    let x = size.width * (0.5 + 0.3 * cos(t * 0.7 + Double(i)))
                    let y = size.height * (0.5 + 0.3 * sin(t * 0.5 + Double(i) * 1.5))
                    let radius = min(size.width, size.height) * (0.3 + 0.1 * sin(t * 0.3))
                    
                    let tint: Color = OverlayTheme.isContainerMode
                        ? (i % 2 == 0 ? Color.blue.opacity(0.12) : Color.cyan.opacity(0.10))
                        : (i % 2 == 0 ? Color.purple.opacity(0.12) : Color.indigo.opacity(0.10))
                    let color = tint
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
                
                // Subtle glass wash
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.white.opacity(0.05)))
            }
            .blur(radius: 80)
        }
        .ignoresSafeArea()
    }
}

struct OverlayPanelModifier: ViewModifier {
    var radius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(
                VisualEffectView(
                    material: .hudWindow,
                    blendingMode: .withinWindow,
                    state: .active
                )
            )
            .background(OverlayTheme.panel.opacity(0.7))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(OverlayTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func overlayPanel(radius: CGFloat = 20) -> some View {
        modifier(OverlayPanelModifier(radius: radius))
    }
}
