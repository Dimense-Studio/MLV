import AppKit
import SwiftUI

struct DarkGlassBackground: View {
    var cornerRadius: CGFloat = 16
    
    var body: some View {
        DarkVisualEffectView(
            material: .hudWindow,
            blendingMode: .withinWindow,
            state: NSVisualEffectView.State.active,
            appearance: NSAppearance.Name.vibrantDark
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.02),
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)
                .opacity(0.7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct DarkVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    var appearance: NSAppearance.Name?
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        if let appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        if let appearance {
            nsView.appearance = NSAppearance(named: appearance)
        } else {
            nsView.appearance = nil
        }
    }
}
