import SwiftUI
import Virtualization

struct VMConsoleWindow: View {
    let vm: VirtualMachine
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(vm.name)
                    .font(.headline)
                Spacer()
                StatusBadge(state: vm.state)
            }
            .padding()
            
            Divider()
            
            if let virtualMachine = vm.vzVirtualMachine {
                VMDisplayView(virtualMachine: virtualMachine)
                    .frame(minHeight: 360)
            } else {
                ContentUnavailableView("Console not available", systemImage: "display")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
