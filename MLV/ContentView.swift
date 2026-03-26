//
//  ContentView.swift
//  MLV - Mac Linux Virtualization Cluster
//
//  Created by DANNY from DIMENSE.NET on 26.03.2026.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Virtualization   // For Linux VMs

extension UTType {
    /// Uniform Type for ISO disk images (by filename extension)
    static var iso: UTType { UTType(filenameExtension: "iso") ?? .data }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: [SortDescriptor(\Item.timestamp, order: .reverse)]) private var items: [Item]
    
    @State private var searchText: String = ""
    @State private var errorMessage: String? = nil
    @State private var showingError = false
    @State private var selectedTab: ClusterTab = .vms
    
    enum ClusterTab: String, CaseIterable {
        case vms = "Virtual Machines"
        case pods = "Kubernetes Pods"
        case storage = "Distributed Storage"
        
        var icon: String {
            switch self {
            case .vms: return "macwindow"
            case .pods: return "shippingbox.fill"
            case .storage: return "externaldrive.connected.to.line.below"
            }
        }
    }
    
    @State private var showingISOImporter = false
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedTab) {
                    Section {
                        ForEach(ClusterTab.allCases, id: \.self) { tab in
                            NavigationLink(value: tab) {
                                Label(tab.rawValue, systemImage: tab.icon)
                                    .padding(.vertical, 4)
                            }
                        }
                    } header: {
                        Text("Cluster")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    
                    Section {
                        Button {
                            showingISOImporter = true
                        } label: {
                            Label("Authorize Cluster ISO", systemImage: VMManager.shared.authorizedISOURL == nil ? "lock.shield" : "checkmark.shield.fill")
                                .foregroundStyle(VMManager.shared.authorizedISOURL == nil ? .orange : .green)
                        }
                    } header: {
                        Text("Security")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                
                Spacer()
                
                // Sidebar Footer - Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multiverse")
                        .font(.caption2.bold())
                    Text("Powered by DIMENSE.NET")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        } detail: {
            ZStack {
                Color.black.opacity(0.1).ignoresSafeArea()
                
                switch selectedTab {
                case .vms:
                    VMListView(onConsole: { vm in
                        openWindow(id: "console", value: vm.id)
                    })
                    .navigationTitle("Virtual Machines")
                case .pods:
                    PodsListView()
                        .navigationTitle("Kubernetes Pods")
                case .storage:
                    StorageListView()
                        .navigationTitle("Distributed Storage")
                }
            }
            .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showingISOImporter,
            allowedContentTypes: [.iso],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // Start accessing before saving bookmark to ensure we have permission
                    let didStartAccess = url.startAccessingSecurityScopedResource()
                    defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
                    
                    VMManager.shared.authorizedISOURL = url
                }
            case .failure(let error):
                errorMessage = "Failed to authorize ISO: \(error.localizedDescription)"
                showingError = true
            }
        }
        .alert("Error", isPresented: $showingError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { error in
            Text(error)
        }
    }
}

struct VMListView: View {
    let onConsole: (VirtualMachine) -> Void
    @State private var showingConfigForm = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header with Add Button
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Nodes")
                            .font(.title2.bold())
                        Text("\(VMManager.shared.virtualMachines.count) Nodes Provisioned")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    
                    Button {
                        showingConfigForm = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Node")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)

                LazyVStack(spacing: 16) {
                    if VMManager.shared.virtualMachines.isEmpty {
                        ContentUnavailableView("No Nodes Active", systemImage: "server.rack", description: Text("Click 'Add Node' to deploy a new Debian 13 server"))
                            .padding(.top, 100)
                    } else {
                        ForEach(VMManager.shared.virtualMachines) { vm in
                            VMCard(vm: vm, onConsole: {
                                onConsole(vm)
                            })
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showingConfigForm) {
            VMConfigForm()
        }
    }
}

struct VMCard: View {
    let vm: VirtualMachine
    let onConsole: () -> Void
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(Color.accentColor)
                        Text(vm.name)
                            .font(.system(.headline, design: .rounded))
                        
                        if vm.isMaster {
                            Text("MASTER")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundStyle(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }
                    Text(vm.isInstalled ? "Debian 13 Trixie Server" : "Provisioning System...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    Button {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Delete VM and Disks")
                    
                    StatusBadge(state: vm.state)
                }
            }
            
            // Resource Info
            HStack(spacing: 16) {
                Label("\(vm.cpuCount) CPUs", systemImage: "memorychip")
                Label("\(vm.memorySizeGB) GB RAM", systemImage: "bolt.fill")
                Label("\(vm.systemDiskSizeGB) GB System", systemImage: "internaldrive")
                Label("\(vm.dataDiskSizeGB) GB Data", systemImage: "externaldrive")
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: vm.networkInterfaceType.icon)
                    Text(vm.networkSpeed)
                }
                .foregroundStyle(Color.accentColor)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            
            Divider().opacity(0.1)
            
            HStack(spacing: 12) {
                if vm.state == .stopped {
                    Button {
                        Task { try? await VMManager.shared.startVM(vm) }
                    } label: {
                        Label(vm.isInstalled ? "Start" : "Deploy", systemImage: vm.isInstalled ? "play.fill" : "cloud.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if case .error(let msg) = vm.state {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deployment Failed")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task { try? await VMManager.shared.startVM(vm) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Group {
                        Button {
                            Task { try? await VMManager.shared.stopVM(vm) }
                        } label: {
                            Image(systemName: "power")
                        }
                        .help("Power Off")
                        
                        Button {
                            Task { try? await VMManager.shared.restartVM(vm) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Restart")
                        
                        Button {
                            VMManager.shared.openVMFolder(vm)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Open VM Files")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    Spacer()
                    
                    Button {
                        onConsole()
                    } label: {
                        Label("Console", systemImage: "terminal.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.regular)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .confirmationDialog("Are you sure?", isPresented: $showingDeleteConfirmation) {
            Button("Delete VM and all Disks", role: .destructive) {
                VMManager.shared.removeVM(vm)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the virtual machine and all associated disk images (system.img and data.img).")
        }
    }
}

struct PodsListView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("Cluster Orchestration")
                        .font(.title2.bold())
                    Spacer()
                    Image(systemName: "shippingbox.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.bottom, 8)

                if VMManager.shared.virtualMachines.filter({ $0.state == .running }).isEmpty {
                    ContentUnavailableView("No Running Nodes", systemImage: "bolt.horizontal.circle", description: Text("Deploy and start a Linux node to see active Kubernetes pods"))
                        .padding(.top, 50)
                } else {
                    ForEach(VMManager.shared.virtualMachines.filter({ $0.state == .running })) { vm in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(vm.name, systemImage: "server.rack")
                                    .font(.headline)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                            
                            VStack(spacing: 10) {
                                PodRow(name: "coredns-78fcdf6894", status: "Running", cpu: "12m", ram: "18Mi")
                                PodRow(name: "longhorn-manager-v2", status: "Running", cpu: "45m", ram: "124Mi")
                                PodRow(name: "k3s-agent-init", status: "Running", cpu: "10m", ram: "64Mi")
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    }
                }
            }
            .padding()
        }
    }
}

struct PodRow: View {
    let name: String
    let status: String
    let cpu: String
    let ram: String
    @State private var isHovered = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status == "Running" ? .green : (status == "Pending" ? .orange : .red))
                        .frame(width: 6, height: 6)
                    Text(name)
                        .font(.system(.subheadline, design: .monospaced))
                        .fontWeight(.medium)
                }
                Text(status)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(status == "Running" ? .green.opacity(0.8) : .orange.opacity(0.8))
                    .padding(.leading, 12)
            }
            Spacer()
            
            HStack(spacing: 16) {
                ResourceMetric(label: "CPU", value: cpu)
                ResourceMetric(label: "RAM", value: ram)
                
                Menu {
                    Section("Management") {
                        Button { } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button { } label: { Label("View Logs", systemImage: "doc.text") }
                        Button { } label: { Label("Shell", systemImage: "terminal") }
                    }
                    Section {
                        Button(role: .destructive) { } label: { Label("Terminate", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(isHovered ? 0.1 : 0))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(isHovered ? 0.05 : 0.02))
        .cornerRadius(10)
        .onHover { isHovered = $0 }
    }
}

struct ResourceMetric: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

struct StorageListView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("Distributed Nodes Storage")
                        .font(.title2.bold())
                    Spacer()
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.bottom, 8)

                if VMManager.shared.virtualMachines.isEmpty {
                    ContentUnavailableView("No Storage Active", systemImage: "externaldrive.badge.xmark", description: Text("Start a node to see allocated disk space"))
                        .padding(.top, 50)
                } else {
                    ForEach(VMManager.shared.virtualMachines) { vm in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(vm.name, systemImage: "server.rack")
                                    .font(.headline)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                            
                            VStack(spacing: 8) {
                                StorageFileRow(name: "system.img", size: "\(vm.systemDiskSizeGB) GB", type: "OS & Boot")
                                StorageFileRow(name: "data.img", size: "\(vm.dataDiskSizeGB) GB", type: "Longhorn Block Storage")
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                    }
                }
            }
            .padding()
        }
    }
}

struct StorageFileRow: View {
    let name: String
    let size: String
    let type: String
    
    var body: some View {
        HStack {
            Image(systemName: "doc.plaintext.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(name)
                    .font(.system(.subheadline, design: .monospaced))
                Text(type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(size)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(6)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct StatusBadge: View {
    let state: VMState
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.2))
        .cornerRadius(4)
    }
    
    var statusColor: Color {
        switch state {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        }
    }
    
    var statusText: String {
        switch state {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }
}



#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}

struct VMConfigForm: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var vmName: String = ""
    @State private var cpuCount: Double = 4
    @State private var memoryGB: Double = 4
    @State private var systemDiskGB: Double = 64
    @State private var dataDiskGB: Double = 100
    @State private var isMaster: Bool = false
    @State private var selectedInterfaceIndex: Int = 0
    @State private var errorMessage: String? = nil
    @State private var isDeploying: Bool = false
    @State private var showingISOImporter = false
    
    // Real Host Limits
    private let maxCores = Double(max(1, HostResources.cpuCount - 2))
    private let maxRAM = Double(max(2, HostResources.totalMemoryGB - 2))
    private let freeDisk = Double(HostResources.freeDiskSpaceGB)
    private let interfaces = HostResources.getNetworkInterfaces()
    
    private var isISOAuthorized: Bool {
        VMManager.shared.authorizedISOURL != nil || Bundle.main.url(forResource: "debian-13.1.0-arm64-netinst", withExtension: "iso") != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deploy New Node")
                        .font(.title2.bold())
                    Text("Debian 13 Trixie Server Template")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(.ultraThinMaterial)
            
            ScrollView {
                VStack(spacing: 24) {
                    // ISO Authorization Warning
                    if !isISOAuthorized {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "lock.shield.fill")
                                    .foregroundStyle(.orange)
                                Text("ISO Authorization Required")
                                    .font(.headline)
                            }
                            Text("Due to macOS Sandboxing, you must explicitly authorize the Debian 13 ISO before deployment can begin.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Button {
                                showingISOImporter = true
                            } label: {
                                Label("Select & Authorize ISO", systemImage: "doc.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                    }

                    // Role Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Node Role", systemImage: "rectangle.stack.badge.person.crop")
                            .font(.headline)
                        
                        HStack(spacing: 12) {
                            RoleButton(
                                title: "Control Plane",
                                subtitle: "K3s Master / API",
                                icon: "crown.fill",
                                isSelected: isMaster,
                                color: .accentColor
                            ) {
                                isMaster = true
                            }
                            
                            RoleButton(
                                title: "Worker Node",
                                subtitle: "K3s Agent / Storage",
                                icon: "shippingbox.fill",
                                isSelected: !isMaster,
                                color: .secondary
                            ) {
                                isMaster = false
                            }
                        }
                        
                        if isMaster && VMManager.shared.virtualMachines.contains(where: { $0.isMaster }) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("A Control Plane already exists in this cluster. Multiple masters require HA configuration.")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                        }
                    }
                    
                    Divider().opacity(0.1)
                    
                    // Name Section
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Node Identity", systemImage: "tag.fill")
                            .font(.headline)
                        
                        TextField("Enter Node Name", text: $vmName)
                            .textFieldStyle(.plain)
                            .padding()
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(8)
                    }
                    
                    Divider().opacity(0.1)
                    
                    // Hardware Sliders
                    VStack(spacing: 20) {
                        ConfigSlider(
                            label: "Compute Cores",
                            value: $cpuCount,
                            range: 1...Double(HostResources.cpuCount),
                            step: 1,
                            unit: "Cores",
                            icon: "memorychip",
                            safeMax: maxCores
                        )
                        
                        ConfigSlider(
                            label: "Memory (RAM)",
                            value: $memoryGB,
                            range: 2...Double(HostResources.totalMemoryGB),
                            step: 2,
                            unit: "GB",
                            icon: "bolt.fill",
                            safeMax: maxRAM
                        )
                        
                        ConfigSlider(
                            label: "System Disk",
                            value: $systemDiskGB,
                            range: 20...freeDisk,
                            step: 4,
                            unit: "GB",
                            icon: "internaldrive",
                            safeMax: freeDisk * 0.8
                        )
                        
                        ConfigSlider(
                            label: "Data Disk (Longhorn)",
                            value: $dataDiskGB,
                            range: 20...freeDisk,
                            step: 10,
                            unit: "GB",
                            icon: "externaldrive",
                            safeMax: freeDisk * 0.8
                        )
                    }
                    
                    Divider().opacity(0.1)
                    
                    // Network Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cluster Fabric", systemImage: "network")
                            .font(.headline)
                        
                        Picker("Select Interface", selection: $selectedInterfaceIndex) {
                            ForEach(0..<interfaces.count, id: \.self) { index in
                                HStack {
                                    Image(systemName: interfaces[index].type.icon)
                                    Text(interfaces[index].name)
                                    if interfaces[index].isActive {
                                        Text("(Active)")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.green)
                                    }
                                }
                                .tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(8)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        
                        Text("Recommended: \(interfaces[selectedInterfaceIndex].type == .ethernet || interfaces[selectedInterfaceIndex].type == .thunderbolt ? "Ethernet/Thunderbolt for high-speed cluster storage." : "WiFi may limit Longhorn performance.")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            
            // Footer
            VStack(spacing: 12) {
                if let error = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                            .font(.caption)
                    }
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                }
                
                Divider().opacity(0.1)
                
                Button {
                    deploy()
                } label: {
                    HStack {
                        if isDeploying {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 8)
                        }
                        Text(isDeploying ? "Provisioning..." : "Create & Deploy Node")
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .disabled(isDeploying || !isISOAuthorized)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(.ultraThinMaterial)
        }
        .frame(width: 450, height: 750)
        .fileImporter(
            isPresented: $showingISOImporter,
            allowedContentTypes: [.iso],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                // Start accessing before saving bookmark to ensure we have permission
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
                
                VMManager.shared.authorizedISOURL = url
            }
        }
        .onAppear {
            if vmName.isEmpty {
                vmName = "mlv-node-\(Int.random(in: 10...99))"
            }
            
            // Auto-detect the best network interface
            if let activeIndex = interfaces.firstIndex(where: { $0.isActive }) {
                selectedInterfaceIndex = activeIndex
            } else {
                selectedInterfaceIndex = 0
            }
            
            // Set reasonable defaults within safe zones
            cpuCount = min(4, maxCores)
            memoryGB = min(4, maxRAM)
            
            // Suggest role: if no master exists, suggest master
            if !VMManager.shared.virtualMachines.contains(where: { $0.isMaster }) {
                isMaster = true
            } else {
                isMaster = false
            }
        }
    }
    
    private func deploy() {
        let interface = interfaces[selectedInterfaceIndex]
        isDeploying = true
        errorMessage = nil
        
        Task {
            do {
                _ = try await VMManager.shared.createLinuxVM(
                    name: vmName,
                    cpus: Int(cpuCount),
                    ramGB: Int(memoryGB),
                    sysDiskGB: Int(systemDiskGB),
                    dataDiskGB: Int(dataDiskGB),
                    isMaster: isMaster,
                    networkType: interface.type,
                    bsdName: interface.bsdName,
                    networkSpeed: interface.speed
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDeploying = false
            }
        }
    }
}

struct RoleButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ConfigSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let icon: String
    let safeMax: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline.bold())
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(value > safeMax ? .red : Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((value > safeMax ? Color.red : Color.accentColor).opacity(0.1))
                    .cornerRadius(4)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)
                    
                    // Safe zone (Green)
                    Capsule()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: geometry.size.width * CGFloat((safeMax - range.lowerBound) / (range.upperBound - range.lowerBound)), height: 4)
                    
                    // Danger zone (Red)
                    Capsule()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: geometry.size.width * CGFloat((range.upperBound - safeMax) / (range.upperBound - range.lowerBound)), height: 4)
                        .offset(x: geometry.size.width * CGFloat((safeMax - range.lowerBound) / (range.upperBound - range.lowerBound)))
                }
            }
            .frame(height: 4)
            
            Slider(value: $value, in: range, step: step)
                .tint(value > safeMax ? .red : Color.accentColor)
            
            if value > safeMax {
                Text("Warning: Exceeding recommended host reservation")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
