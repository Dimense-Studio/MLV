import SwiftUI
import Virtualization

struct VMConsoleWindow: View {
    let vm: VirtualMachine
    @Environment(\.dismiss) private var dismiss
    @State private var showingProgressOverlay = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Title Bar - Glass Effect
            HStack {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.name)
                            .font(.headline)
                        Text(vm.isInstalled ? "Node Online" : "Installing OS...")
                            .font(.caption2)
                            .foregroundStyle(vm.isInstalled ? .green : .yellow)
                    }
                }
                
                Spacer()
                
                if !vm.isInstalled {
                    Button {
                        showingProgressOverlay.toggle()
                    } label: {
                        Label(showingProgressOverlay ? "Hide Progress" : "Show Progress", systemImage: "clock.badge.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.leading, 8)
                }
                
                Button {
                    vm.addLog("Refreshing console view...")
                } label: {
                    Image(systemName: "viewfinder")
                }
                .help("Refresh View")
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                
                Spacer()
                
                HStack(spacing: 20) {
                    Button {
                        Task { try? await VMManager.shared.restartVM(vm) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Restart Node")
                    
                    Button(role: .destructive) {
                        Task { try? await VMManager.shared.stopVM(vm) }
                        dismiss()
                    } label: {
                        Image(systemName: "power")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Power Off")
                    
                    Divider().frame(height: 20)
                    
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.bold())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(VisualEffectView(material: .titlebar, blendingMode: .withinWindow))
            
            Divider()
            
            ZStack {
                // Actual VM Console (Always running in background)
                Group {
                    if let vzVM = vm.vzVirtualMachine {
                        VMGraphicsView(virtualMachine: vzVM, isOverlayShowing: showingProgressOverlay && !vm.isInstalled)
                            .background(Color.black)
                            .allowsHitTesting(!showingProgressOverlay || vm.isInstalled)
                    } else {
                        VStack(spacing: 20) {
                            ProgressView()
                            Text("Waiting for engine...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    }
                }
                
                // Deployment Progress Overlay
                if !vm.isInstalled && vm.state == .running && showingProgressOverlay && !vm.needsUserInteraction {
                    Color.black.opacity(0.85)
                        .transition(.opacity)
                    
                    DeploymentProgressView(vm: vm)
                        .padding(40)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(.ultraThinMaterial)
                                .shadow(radius: 20)
                        )
                        .frame(maxWidth: 600, maxHeight: 500)
                        .transition(.scale.combined(with: .opacity))
                }
                
                // User Interaction Required Overlay (Slightly different)
                if vm.needsUserInteraction && !vm.isInstalled {
                    VStack {
                        Spacer()
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Installer needs attention. Use the GUI console to respond.")
                                    .font(.headline)
                            }
                            
                            HStack(spacing: 16) {
                                Button {
                                    VMManager.shared.fetchInstallerLogs(for: vm)
                                } label: {
                                    Label("Fetch Syslog Diagnostics", systemImage: "doc.text.magnifyingglass")
                                }
                                .buttonStyle(.bordered)
                                
                                Button("Acknowledge") {
                                    vm.needsUserInteraction = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom))
                }
                
                // Starting overlay
                if vm.state == .starting {
                    Color.black
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Initializing Node...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(), value: showingProgressOverlay)
            .animation(.spring(), value: vm.state)
        }
        .frame(minWidth: 1024, minHeight: 768)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

struct DeploymentProgressView: View {
    let vm: VirtualMachine
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, options: .repeating)
                
                Text("Installing Node")
                    .font(.title2.bold())
                
                Text("Debian 13 Trixie + K3s + Longhorn")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 8) {
                ProgressView(value: vm.deploymentProgress)
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
                
                HStack {
                    Text(currentStepMessage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(vm.deploymentProgress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
            }
            
            // Recent Logs
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("DEPLOYMENT LOGS")
                        .font(.system(size: 8, weight: .bold))
                    Spacer()
                    Button {
                        let allLogs = vm.deploymentLogs.map { "[\($0.timestamp)] \($0.message)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(allLogs, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    
                    ProgressView()
                        .controlSize(.mini)
                }
                .foregroundStyle(.secondary)
                
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(vm.deploymentLogs) { log in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(log.timestamp, style: .time)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(log.message)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(log.isError ? .red : .primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(log.id)
                            }
                        }
                        .onChange(of: vm.deploymentLogs.count) {
                            if let lastLog = vm.deploymentLogs.last {
                                withAnimation { proxy.scrollTo(lastLog.id, anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            .padding()
            .background(Color.black.opacity(0.3))
            .cornerRadius(12)
            
            Text("The system will automatically restart once installation is complete.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
    
    private var currentStepMessage: String {
        vm.deploymentLogs.last?.message ?? "Initializing..."
    }
}

struct VMGraphicsView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let isOverlayShowing: Bool
    
    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine
        view.capturesSystemKeys = !isOverlayShowing
        
        // Ensure the view has a non-zero frame immediately to avoid the "0x0 scanout" error
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        
        return view
    }
    
    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== virtualMachine {
            nsView.virtualMachine = virtualMachine
        }
        
        // Dynamically toggle system key capture
        if nsView.capturesSystemKeys == isOverlayShowing {
            nsView.capturesSystemKeys = !isOverlayShowing
        }
        
        // Force the arrow cursor to be shown if the overlay is visible
        if isOverlayShowing {
            DispatchQueue.main.async {
                NSCursor.arrow.set()
                // If the view is still trying to hide the cursor, we need to force it back
                NSCursor.unhide()
            }
        }
    }
}
