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
import AppKit

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
        case network = "Network Topology"
        
        var icon: String {
            switch self {
            case .vms: return "macwindow"
            case .pods: return "shippingbox.fill"
            case .storage: return "externaldrive.connected.to.line.below"
            case .network: return "network"
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
                    VMListView()
                    .navigationTitle("Virtual Machines")
                case .pods:
                    PodsListView()
                        .navigationTitle("Kubernetes Pods")
                case .storage:
                    StorageListView()
                        .navigationTitle("Distributed Storage")
                case .network:
                    NetworkListView()
                        .navigationTitle("Network Topology")
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
    @State private var showingConfigForm = false
    @State private var addButtonGlow = false
    @State private var selectedVMID: UUID? = nil
    @State private var search: String = ""
    
    var body: some View {
        let all = VMManager.shared.virtualMachines
        let filtered = all.filter { search.isEmpty ? true : $0.name.localizedCaseInsensitiveContains(search) }
        let selectedVM = filtered.first(where: { $0.id == selectedVMID }) ?? filtered.first
        
        return ZStack {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Virtual Machines")
                            .font(.title2.bold())
                        Text("\(all.count) total • \(all.filter(\.state.isRunning).count) running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    
                    HostMetricChip(systemName: "cpu", title: "\(HostResources.cpuCount) Cores")
                    HostMetricChip(systemName: "memorychip", title: "\(HostResources.totalMemoryGB) GB RAM")
                    HostMetricChip(systemName: "internaldrive", title: "\(HostResources.freeDiskSpaceGB) GB Free")
                    
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .font(.system(size: 12))
                    
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showingConfigForm = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .black))
                                .symbolEffect(.pulse.byLayer, options: .repeating, value: addButtonGlow)
                            Text("Deploy Node")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .cornerRadius(18)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                
                HSplitView {
                    List(selection: $selectedVMID) {
                        if filtered.isEmpty {
                            ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try a different search"))
                        } else {
                            ForEach(filtered) { vm in
                                VMRowCompact(vm: vm)
                                    .tag(vm.id)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 360, idealWidth: 380, maxWidth: 420)
                    
                    Group {
                        if let selectedVM {
                            VMInspector(vm: selectedVM)
                                .padding(.horizontal)
                                .padding(.bottom, 14)
                        } else {
                            ContentUnavailableView("Select a VM", systemImage: "macwindow", description: Text("Choose a VM from the list to view details"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .onAppear {
                    if selectedVMID == nil {
                        selectedVMID = filtered.first?.id
                    }
                    addButtonGlow = true
                }
                .onChange(of: search) {
                    if selectedVMID == nil || !filtered.contains(where: { $0.id == selectedVMID }) {
                        selectedVMID = filtered.first?.id
                    }
                }
                .onChange(of: all.count) {
                    if selectedVMID == nil {
                        selectedVMID = filtered.first?.id
                    }
                }
            }
            
            if showingConfigForm {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation { showingConfigForm = false }
                    }
                
                VMConfigForm(isPresented: $showingConfigForm)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
    }
}

struct HostMetricChip: View {
    let systemName: String
    let title: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

struct VMRowCompact: View {
    let vm: VirtualMachine
    
    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(state: vm.state)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(vm.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    if vm.isMaster {
                        Text("MASTER")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(AnyShapeStyle(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(AnyShapeStyle(Color.accentColor))
                            .cornerRadius(4)
                    }
                    Text(vm.selectedDistro.shortLabel.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .foregroundStyle(AnyShapeStyle(.secondary.opacity(0.8)))
                        .cornerRadius(4)
                }
                
                Text(vm.ipAddress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(vm.ipAddress == "Detecting..." ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.85)))
            }
            
            Spacer()
            
            HStack(spacing: 10) {
                Text("\(vm.cpuCount)C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(vm.memorySizeGB)G")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

struct VMInspector: View {
    let vm: VirtualMachine
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.name)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(vm.stage.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Autostart", isOn: Binding(get: { vm.autoStartOnLaunch }, set: { vm.autoStartOnLaunch = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                
                HStack(spacing: 10) {
                    Button {
                        Task { try? await VMManager.shared.startVM(vm) }
                    } label: {
                        Label(vm.isInstalled ? "Start" : "Deploy", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.state != .stopped)
                    
                    Button {
                        Task { try? await VMManager.shared.stopVM(vm) }
                    } label: {
                        Label("Stop", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.state.isRunning)
                    
                    Button {
                        Task { try? await VMManager.shared.restartVM(vm) }
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vm.state.isRunning)
                    
                    Spacer()
                    
                    Button {
                        openWindow(id: "console", value: vm.id)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Label("Console", systemImage: "display")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        VMManager.shared.openVMFolder(vm)
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Resources")
                        .font(.headline)
                    HStack(spacing: 12) {
                        InspectorPill(title: "CPU", value: "\(vm.cpuCount)")
                        InspectorPill(title: "RAM", value: "\(vm.memorySizeGB) GB")
                        InspectorPill(title: "System", value: "\(vm.systemDiskSizeGB) GB")
                        InspectorPill(title: "Data", value: "\(vm.dataDiskSizeGB) GB")
                    }
                }
                .padding(16)
                .background(DarkGlassBackground(cornerRadius: 16))
                
                VStack(alignment: .leading, spacing: 10) {
                    Text("Networking")
                        .font(.headline)
                    HStack(spacing: 12) {
                        InspectorPill(title: "Mode", value: vm.networkMode.rawValue)
                        InspectorPill(title: "IP", value: vm.ipAddress)
                        InspectorPill(title: "Gateway", value: vm.gateway)
                    }
                }
                .padding(16)
                .background(DarkGlassBackground(cornerRadius: 16))
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Events")
                            .font(.headline)
                        Spacer()
                        Text("\(vm.deploymentLogs.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    
                    if vm.deploymentLogs.isEmpty {
                        Text("No events yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(vm.deploymentLogs.suffix(30)) { log in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle()
                                        .fill(log.isError ? Color.red : Color.white.opacity(0.3))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(log.message)
                                            .font(.system(size: 11, design: .rounded))
                                            .foregroundStyle(log.isError ? .red.opacity(0.9) : .primary.opacity(0.9))
                                        Text(log.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                )
                                .cornerRadius(12)
                            }
                        }
                    }
                }
                .padding(16)
                .background(DarkGlassBackground(cornerRadius: 16))
            }
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
    }
}

struct InspectorPill: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

struct VMCard: View {
    let vm: VirtualMachine
    @Environment(\.openWindow) private var openWindow
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
                                .background(AnyShapeStyle(Color.accentColor.opacity(0.2)))
                                .foregroundStyle(AnyShapeStyle(Color.accentColor))
                                .cornerRadius(4)
                        }

                        Text(vm.selectedDistro.shortLabel.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.08))
                            .foregroundStyle(AnyShapeStyle(.secondary.opacity(0.8)))
                            .cornerRadius(4)
                        
                        Text(vm.stage.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(AnyShapeStyle(Color.accentColor))
                            .cornerRadius(4)
                    }
                    Text(vm.isInstalled ? vm.selectedDistro.rawValue : "Provisioning System...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    Toggle("Autostart", isOn: Binding(get: { vm.autoStartOnLaunch }, set: { vm.autoStartOnLaunch = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Start VM automatically when MLV launches")
                    Button {
                        openWindow(id: "console", value: vm.id)
                        NSApp.activate(ignoringOtherApps: true)
                    } label: {
                        Image(systemName: "display")
                    }
                    .buttonStyle(.plain)
                    .help("Open GUI console")
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
                HStack(spacing: 6) {
                    SymbolImage(
                        name: vm.networkMode == .bridge ? "point.3.connected.trianglepath" : "arrow.trianglehead.2.clockwise.rotate.90",
                        fallback: vm.networkMode == .bridge ? "cable.connector" : "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    Text(vm.networkMode.rawValue)
                }
                .foregroundStyle(AnyShapeStyle(Color.accentColor))
                if vm.networkMode == .bridge {
                    Text(vm.bridgeInterfaceName ?? "No interface")
                        .foregroundStyle(AnyShapeStyle(.secondary))
                }
            }
            .font(.caption2)
            .foregroundStyle(AnyShapeStyle(.secondary))
            
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
                    
                    if vm.downloadTask != nil {
                        Button {
                            Task { try? await VMManager.shared.stopVM(vm) }
                        } label: {
                            Label("Cancel Download", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Button {
                        Task { try? await VMManager.shared.startVM(vm) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if vm.downloadTask != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloading ISO...")
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                        ProgressView(value: Double(vm.downloadPercent), total: 100.0)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        Text("\(vm.downloadPercent)% • \(vm.downloadSpeedMBps, specifier: "%.1f") MB/s • ETA \(vm.downloadETASeconds / 60)m \(vm.downloadETASeconds % 60)s")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task { try? await VMManager.shared.stopVM(vm) }
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
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
                }
            }
            .controlSize(.regular)
        }
        .padding(20)
        .background(
            DarkGlassBackground(cornerRadius: 16)
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
                            
                            if vm.pods.isEmpty {
                                HStack {
                                    ProgressView().scaleEffect(0.5)
                                    Text("Detecting pods...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 10)
                            } else {
                                VStack(spacing: 10) {
                                    ForEach(vm.pods) { pod in
                                        PodRow(name: pod.name, status: pod.status, cpu: pod.cpu, ram: pod.ram, namespace: pod.namespace)
                                    }
                                }
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
    let namespace: String
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
                    
                    Text(namespace)
                        .font(.system(size: 8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(3)
                }
                Text(status)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(status == "Running" ? AnyShapeStyle(.green.opacity(0.8)) : AnyShapeStyle(.orange.opacity(0.8)))
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
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text(type)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(size)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

struct NetworkListView: View {
    @State private var showConfig = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cluster Networking")
                            .font(.title2.bold())
                        Text("Real-time topology and link speeds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "network")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WireGuard Mesh")
                                .font(.headline)
                            Text("Autodiscovery + secure multi-host cluster overlay")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            withAnimation { showConfig.toggle() }
                        } label: {
                            Text(showConfig ? "Hide Config" : "Show Config")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("THIS HOST")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            Text("\(WireGuardManager.shared.hostInfo.name) • \(WireGuardManager.shared.publicKeyShort)…")
                                .font(.system(size: 11, design: .monospaced))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Text("PORT \(WireGuardManager.shared.listenPort)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                            Button {
                                WireGuardManager.shared.copyConfigToClipboard()
                            } label: {
                                Text("Copy Config")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                WireGuardManager.shared.openConfigInWireGuard()
                            } label: {
                                Text("Open in WireGuard")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            
                            Button {
                                WireGuardManager.shared.revealConfigInFinder()
                            } label: {
                                Text("Reveal")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CLUSTER TOKEN")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            TextField("Shared token (must match across Macs)", text: Binding(
                                get: { VMManager.shared.clusterToken },
                                set: {
                                    VMManager.shared.clusterToken = $0
                                    WireGuardManager.shared.startDiscovery()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(VMManager.shared.clusterToken, forType: .string)
                        } label: {
                            Text("Copy")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }

                    if !DiscoveryManager.shared.discovered.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DISCOVERED")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            ForEach(DiscoveryManager.shared.discovered) { host in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.name)
                                            .font(.system(size: 11, weight: .bold))
                                        Text(DiscoveryManager.shared.pairStatusByID[host.id] ?? "Tap Pair to sync keys")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        WireGuardManager.shared.pair(discovered: host)
                                    } label: {
                                        Text("Pair")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.16))
                                            .cornerRadius(10)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(10)
                            }
                        }
                    }

                    if !WireGuardManager.shared.peers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PAIRED")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            ForEach(WireGuardManager.shared.peers) { peer in
                                HStack {
                                    Text(peer.name)
                                        .font(.system(size: 11, weight: .bold))
                                    Spacer()
                                    Text(peer.addressCIDR)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(10)
                            }
                        }
                    }

                    if showConfig {
                        TextEditor(text: .constant(WireGuardManager.shared.exportConfig()))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(height: 180)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(10)
                    }
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
                .padding(.horizontal)

                if VMManager.shared.virtualMachines.isEmpty {
                    ContentUnavailableView("No Network Active", systemImage: "network.badge.shield.half.filled", description: Text("Deploy nodes to visualize the cluster network"))
                        .padding(.top, 100)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(VMManager.shared.virtualMachines) { vm in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Label(vm.name, systemImage: "server.rack")
                                        .font(.headline)
                                    Spacer()
                                    if vm.state == .running {
                                        HStack(spacing: 4) {
                                            Circle().fill(.green).frame(width: 8, height: 8)
                                            Text("Link Active").font(.caption2).bold()
                                        }
                                        .foregroundStyle(.green)
                                    }
                                }
                                
                                HStack(spacing: 20) {
                                    NetworkDetailItem(label: "IP ADDRESS", value: vm.ipAddress, icon: "number")
                                    NetworkDetailItem(label: "GATEWAY", value: vm.gateway, icon: "arrow.up.left.and.arrow.down.right")
                                    NetworkDetailItem(label: "INTERFACE", value: vm.bridgeInterfaceName ?? "-", icon: "cable.connector")
                                }
                                
                                Divider().opacity(0.1)
                                
                                HStack(spacing: 20) {
                                    NetworkDetailItem(label: "MODE", value: vm.networkMode.rawValue, icon: vm.networkMode == .bridge ? "point.3.connected.trianglepath" : "arrow.trianglehead.2.clockwise.rotate.90")
                                    NetworkDetailItem(label: "STATE", value: vm.state.isRunning ? "Running" : "Stopped", icon: "bolt.horizontal")
                                    NetworkDetailItem(label: "DNS", value: vm.dns.joined(separator: ", "), icon: "globe")
                                }
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
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .onAppear {
            WireGuardManager.shared.startDiscovery()
        }
    }
}

struct NetworkDetailItem: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SymbolImage(name: icon, fallback: "questionmark")
                    .font(.system(size: 8))
                Text(label)
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @Binding var isPresented: Bool
    
    @State private var vmName: String = ""
    @State private var cpuCount: Double = 4
    @State private var memoryGB: Double = 4
    @State private var systemDiskGB: Double = 40
    @State private var dataDiskGB: Double = 100
    @State private var useDedicatedLonghornDisk: Bool = true
    @State private var isMaster: Bool = false
    @State private var selectedDistro: VirtualMachine.LinuxDistro = .debian13
    @State private var selectedInterfaceIndex: Int = 0
    @State private var errorMessage: String? = nil
    @State private var isDeploying: Bool = false
    @State private var showingISOImporter = false
    
    // Added network mode and bridge interface selection states
    @State private var selectedNetworkMode: VMNetworkMode = .nat
    @State private var selectedBridgeName: String = ""
    
    // Real Host Limits
    private let maxCores = Double(max(1, HostResources.cpuCount - 2))
    private let maxRAM = Double(max(2, HostResources.totalMemoryGB - 2))
    private let freeDisk = Double(HostResources.freeDiskSpaceGB)
    private let interfaces = HostResources.getNetworkInterfaces()
    
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deploy Node")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Select OS and Resources")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation { isPresented = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Distro Picker
                        VStack(alignment: .leading, spacing: 12) {
                            Text("DISTRIBUTION")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(VirtualMachine.LinuxDistro.allCases) { distro in
                                        DistroCard(distro: distro, isSelected: selectedDistro == distro) {
                                            selectedDistro = distro
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Identity
                        VStack(alignment: .leading, spacing: 12) {
                            Text("IDENTITY")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            
                            TextField("Node Name", text: $vmName)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(8)
                        }
                        
                        // Role
                        HStack(spacing: 12) {
                            RoleButtonMinimal(title: "Master", isSelected: isMaster) { isMaster = true }
                            RoleButtonMinimal(title: "Worker", isSelected: !isMaster) { isMaster = false }
                        }
                        
                        // Resources
                        VStack(spacing: 20) {
                            ConfigSlider(label: "Cores", value: $cpuCount, range: 1...Double(HostResources.cpuCount), step: 1, unit: "", icon: "cpu", safeMax: maxCores)
                            ConfigSlider(label: "RAM", value: $memoryGB, range: 2...Double(HostResources.totalMemoryGB), step: 2, unit: "GB", icon: "bolt.fill", safeMax: maxRAM)
                            ConfigSlider(label: "System Disk", value: $systemDiskGB, range: 5...200, step: 5, unit: "GB", icon: "internaldrive", safeMax: 120)
                            Toggle("Dedicated Longhorn Disk", isOn: $useDedicatedLonghornDisk)
                                .toggleStyle(.switch)
                            if useDedicatedLonghornDisk {
                                ConfigSlider(label: "Longhorn Disk", value: $dataDiskGB, range: 5...500, step: 5, unit: "GB", icon: "externaldrive.connected.to.line.below", safeMax: max(5, freeDisk - systemDiskGB - 10))
                            } else {
                                Text("Longhorn will use system disk (vda). No dedicated vdb disk.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // --- BEGIN INSERT ---
                        VStack(alignment: .leading, spacing: 12) {
                            Text("NETWORK MODE")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.secondary)
                            Picker("Mode", selection: $selectedNetworkMode) {
                                ForEach(VMNetworkMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                            if selectedNetworkMode == .bridge {
                                Picker("Bridge Interface", selection: $selectedBridgeName) {
                                    ForEach(interfaces, id: \.bsdName) { iface in
                                        Text("\(iface.name) [\(iface.bsdName)]").tag(iface.bsdName)
                                    }
                                }
                                .frame(width: 230)
                                .pickerStyle(.menu)
                            }
                        }
                        // --- END INSERT ---
                    }
                    .padding(.horizontal, 24)
                }
                
                // Deploy Button
                Button {
                    deploy()
                } label: {
                    HStack {
                        if isDeploying {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text("DEPLOY NODE")
                                .font(.system(size: 13, weight: .black))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(isDeploying)
                .padding(24)
            }
            .frame(width: 320)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .onAppear {
            if vmName.isEmpty { vmName = "node-\(Int.random(in: 100...999))" }
            // Default bridge interface if available
            if selectedBridgeName.isEmpty, let first = interfaces.first {
                selectedBridgeName = first.bsdName
            }
        }
    }
    
    private func deploy() {
        isDeploying = true
        Task {
            do {
                let vm = try await VMManager.shared.createLinuxVM(
                    name: vmName,
                    cpus: Int(cpuCount),
                    ramGB: Int(memoryGB),
                    sysDiskGB: Int(systemDiskGB),
                    dataDiskGB: useDedicatedLonghornDisk ? Int(dataDiskGB) : 0,
                    isMaster: isMaster,
                    distro: selectedDistro
                )
                // Set properties explicitly if needed (assuming VMManager does so)
                // vm.networkMode = selectedNetworkMode
                // vm.bridgeInterfaceName = selectedNetworkMode == .bridge ? selectedBridgeName : nil
                
                isDeploying = false
                withAnimation { isPresented = false }
            } catch {
                errorMessage = error.localizedDescription
                isDeploying = false
            }
        }
    }
}

struct DistroCard: View {
    let distro: VirtualMachine.LinuxDistro
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: distro.icon == "debian" ? "circle.grid.cross" : (distro.icon == "ubuntu" ? "circle.circle" : "sparkles"))
                    .font(.title2)
                Text(distro.rawValue.components(separatedBy: " ")[0])
                    .font(.system(size: 10, weight: .bold))
            }
            .frame(width: 80, height: 80)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct RoleButtonMinimal: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentColor : Color.white.opacity(0.05))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
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
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.white.opacity(0.03))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))\(unit)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(value > safeMax ? .red : Color.accentColor)
            }
            
            Slider(value: $value, in: range, step: step)
                .tint(value > safeMax ? .red : Color.accentColor)
                .controlSize(.small)
        }
    }
}

// Assuming VMNetworkMode is defined somewhere like this:
// enum VMNetworkMode: String, CaseIterable {
//     case nat = "NAT"
//     case bridge = "Bridge"
// }
// Note: VMManager.shared.createLinuxVM must be updated to accept networkMode: and bridgeInterfaceName: parameters.




