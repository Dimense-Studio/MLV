import SwiftUI
import Virtualization

struct VMConsoleWindow: View {
    let vm: VirtualMachine
    @State private var autoScroll = true
    
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
            
            Divider()
            
            HStack {
                Text("Serial Console")
                    .font(.subheadline.bold())
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.consoleOutput.isEmpty ? "Waiting for console output..." : vm.consoleOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("console-bottom")
                }
                .onChange(of: vm.consoleOutput) {
                    if autoScroll {
                        proxy.scrollTo("console-bottom", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 220)
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
