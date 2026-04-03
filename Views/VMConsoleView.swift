import SwiftUI
import Virtualization

struct VMConsoleWindow: View {
    let vm: VirtualMachine
    
    var body: some View {
        ZStack {
            OverlayCanvasBackground()

            VStack(spacing: 12) {
                HStack {
                    Text(vm.name)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(OverlayTheme.textPrimary)
                    Spacer()
                    StatusBadge(state: vm.state)
                }
                .padding(14)
                .overlayPanel(radius: 16)

                if let virtualMachine = vm.vzVirtualMachine {
                    VMDisplayView(virtualMachine: virtualMachine)
                        .frame(minHeight: 360)
                        .overlayPanel(radius: 16)
                } else {
                    ContentUnavailableView("Console not available", systemImage: "display")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlayPanel(radius: 16)
                }
            }
            .padding(14)
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}

private struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    
    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = true
        return view
    }
    
    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== virtualMachine {
            nsView.virtualMachine = virtualMachine
        }
    }
}
