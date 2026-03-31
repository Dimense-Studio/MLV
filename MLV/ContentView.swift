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
            List(selection: $selectedTab) {
                Section {
                    ForEach(ClusterTab.allCases, id: \.self) { tab in
                        NavigationLink(value: tab) {
                            Label(tab.rawValue, systemImage: tab.icon)
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
        } detail: {
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
        .fileImporter(
            isPresented: $showingISOImporter,
            allowedContentTypes: [.iso],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
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

#if canImport(__Nonexistent__)
#endif

struct VMListView: View {
    @State private var showingConfigForm = false
    @State private var selectedVMID: UUID? = nil
    @State private var search: String = ""
    
    var body: some View {
        let all = VMManager.shared.virtualMachines
        let filtered = all.filter { search.isEmpty ? true : $0.name.localizedCaseInsensitiveContains(search) }
        let selectedVM = filtered.first(where: { $0.id == selectedVMID }) ?? filtered.first
        
        return HSplitView {
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
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            
            Group {
                if let selectedVM {
                    VMInspector(vm: selectedVM)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                } else {
                    ContentUnavailableView("Select a VM", systemImage: "macwindow", description: Text("Choose a VM from the list to view details"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingConfigForm = true
                } label: {
                    Label("Deploy", systemImage: "plus")
                }
            }
            
            ToolbarItem(placement: .automatic) {
                Text("\(all.count) total • \(all.filter(\.state.isRunning).count) running • \(HostResources.cpuCount)C • \(HostResources.totalMemoryGB)G • \(HostResources.freeDiskSpaceGB)G free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingConfigForm) {
            VMConfigForm(isPresented: $showingConfigForm)
        }
        .onAppear {
            if selectedVMID == nil {
                selectedVMID = filtered.first?.id
            }
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
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.body)
                        .lineLimit(1)
                    
                    if vm.isMaster {
                        Text("Master")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    
                    Text(vm.selectedDistro.shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Text(vm.ipAddress)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text("\(vm.cpuCount)C  \(vm.memorySizeGB)G")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct VMInspector: View {
    let vm: VirtualMachine
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.name)
                            .font(.title3.weight(.semibold))
                        Text(vm.stage.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(state: vm.state)
                }
                Toggle("Autostart", isOn: Binding(get: { vm.autoStartOnLaunch }, set: { vm.autoStartOnLaunch = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            
            Section {
                HStack(spacing: 8) {
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
            }
            
            Section("Resources") {
                LabeledContent("CPU", value: "\(vm.cpuCount)")
                LabeledContent("RAM", value: "\(vm.memorySizeGB) GB")
                LabeledContent("System Disk", value: "\(vm.systemDiskSizeGB) GB")
                LabeledContent("Data Disk", value: "\(vm.dataDiskSizeGB) GB")
            }
            
            Section("Networking") {
                LabeledContent("Mode", value: vm.networkMode.rawValue)
                LabeledContent("IP", value: vm.ipAddress)
                    .textSelection(.enabled)
                LabeledContent("Gateway", value: vm.gateway)
                    .textSelection(.enabled)
            }
            
            Section("Events") {
                if vm.deploymentLogs.isEmpty {
                    Text("No events yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.deploymentLogs.suffix(50)) { log in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(log.isError ? Color.red : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(log.message)
                                    .foregroundStyle(log.isError ? Color.red : Color.primary)
                                Text(log.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
        let running = VMManager.shared.virtualMachines.filter { $0.state == .running }
        
        return Group {
            if running.isEmpty {
                ContentUnavailableView("No Running Nodes", systemImage: "bolt.horizontal.circle", description: Text("Deploy and start a Linux node to see active Kubernetes pods"))
            } else {
                List {
                    ForEach(running) { vm in
                        Section {
                            if vm.pods.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Detecting pods…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ForEach(vm.pods) { pod in
                                    PodRow(name: pod.name, status: pod.status, cpu: pod.cpu, ram: pod.ram, namespace: pod.namespace)
                                }
                            }
                        } header: {
                            HStack {
                                Text(vm.name)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct PodRow: View {
    let name: String
    let status: String
    let cpu: String
    let ram: String
    let namespace: String
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status == "Running" ? Color.green : (status == "Pending" ? Color.orange : Color.red))
                .frame(width: 6, height: 6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text("\(namespace) • \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text("\(cpu) • \(ram)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            
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
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.vertical, 4)
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
        let all = VMManager.shared.virtualMachines
        
        return Group {
            if all.isEmpty {
                ContentUnavailableView("No Storage Active", systemImage: "externaldrive.badge.xmark", description: Text("Start a node to see allocated disk space"))
            } else {
                List {
                    ForEach(all) { vm in
                        Section {
                            StorageFileRow(name: "system.img", size: "\(vm.systemDiskSizeGB) GB", type: "OS & Boot")
                            StorageFileRow(name: "data.img", size: "\(vm.dataDiskSizeGB) GB", type: "Longhorn Block Storage")
                        } header: {
                            HStack {
                                Text(vm.name)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(size)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct NetworkListView: View {
    @State private var showConfig = false

    var body: some View {
        let vms = VMManager.shared.virtualMachines
        
        return List {
            Section("WireGuard") {
                LabeledContent("This Host") {
                    Text("\(WireGuardManager.shared.hostInfo.name) • \(WireGuardManager.shared.publicKeyShort)…")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                
                LabeledContent("Listen Port", value: "\(WireGuardManager.shared.listenPort)")
                    .textSelection(.enabled)
                
                HStack(spacing: 8) {
                    Button("Copy Config") { WireGuardManager.shared.copyConfigToClipboard() }
                    Button("Open") { WireGuardManager.shared.openConfigInWireGuard() }
                    Button("Reveal") { WireGuardManager.shared.revealConfigInFinder() }
                }
                
                LabeledContent("Cluster Token") {
                    HStack(spacing: 8) {
                        TextField("Shared token (must match across Macs)", text: Binding(
                            get: { VMManager.shared.clusterToken },
                            set: {
                                VMManager.shared.clusterToken = $0
                                WireGuardManager.shared.startDiscovery()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(VMManager.shared.clusterToken, forType: .string)
                        }
                    }
                }
                
                if showConfig {
                    TextEditor(text: .constant(WireGuardManager.shared.exportConfig()))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                }
            }
            
            if !DiscoveryManager.shared.discovered.isEmpty {
                Section("Discovered") {
                    ForEach(DiscoveryManager.shared.discovered) { host in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text(DiscoveryManager.shared.pairStatusByID[host.id] ?? "Pairing…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("Pair") {
                                WireGuardManager.shared.pair(discovered: host)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            
            if !WireGuardManager.shared.peers.isEmpty {
                Section("Paired") {
                    ForEach(WireGuardManager.shared.peers) { peer in
                        HStack {
                            Text(peer.name)
                            Spacer()
                            Text(peer.addressCIDR)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            
            if !vms.isEmpty {
                Section("Topology") {
                    NetworkTopologyView()
                        .frame(height: 280)
                        .frame(maxWidth: .infinity)
                }
            }
            
            Section("Nodes") {
                if vms.isEmpty {
                    ContentUnavailableView("No Network Active", systemImage: "network.badge.shield.half.filled", description: Text("Deploy nodes to visualize the cluster network"))
                } else {
                    ForEach(vms) { vm in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(vm.name)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                            Text("\(vm.networkMode.rawValue) • IP \(vm.ipAddress) • GW \(vm.gateway)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if vm.networkMode == .bridge, let iface = vm.bridgeInterfaceName {
                                Text("Bridge \(iface)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(showConfig ? "Hide Config" : "Show Config") {
                    showConfig.toggle()
                }
            }
        }
        .onAppear { WireGuardManager.shared.startDiscovery() }
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
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
    @State private var cpuCount: Int = 4
    @State private var memoryGB: Int = 4
    @State private var systemDiskGB: Int = 40
    @State private var dataDiskGB: Int = 100
    @State private var useDedicatedLonghornDisk: Bool = true
    @State private var isMaster: Bool = false
    @State private var selectedDistro: VirtualMachine.LinuxDistro = .debian13
    @State private var errorMessage: String? = nil
    @State private var isDeploying: Bool = false
    
    // Added network mode and bridge interface selection states
    @State private var selectedNetworkMode: VMNetworkMode = .nat
    @State private var selectedBridgeName: String = ""
    
    // Real Host Limits
    private let maxCores = max(1, HostResources.cpuCount - 2)
    private let maxRAM = max(2, HostResources.totalMemoryGB - 2)
    private let freeDisk = HostResources.freeDiskSpaceGB
    private let interfaces = HostResources.getNetworkInterfaces()
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Node Name", text: $vmName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    
                    Picker("Role", selection: $isMaster) {
                        Text("Worker").tag(false)
                        Text("Master").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section("Distribution") {
                    Picker("Linux", selection: $selectedDistro) {
                        ForEach(VirtualMachine.LinuxDistro.allCases) { distro in
                            Text(distro.rawValue).tag(distro)
                        }
                    }
                }
                
                Section("Resources") {
                    Stepper(value: $cpuCount, in: 1...HostResources.cpuCount, step: 1) {
                        HStack {
                            Text("CPU")
                            Spacer()
                            Text("\(cpuCount)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(cpuCount > maxCores ? Color.red : Color.secondary)
                        }
                    }
                    
                    Stepper(value: $memoryGB, in: 2...HostResources.totalMemoryGB, step: 2) {
                        HStack {
                            Text("RAM")
                            Spacer()
                            Text("\(memoryGB) GB")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(memoryGB > maxRAM ? Color.red : Color.secondary)
                        }
                    }
                    
                    Stepper(value: $systemDiskGB, in: 5...200, step: 5) {
                        HStack {
                            Text("System Disk")
                            Spacer()
                            Text("\(systemDiskGB) GB")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Storage") {
                    Toggle("Dedicated Longhorn Disk", isOn: $useDedicatedLonghornDisk)
                    if useDedicatedLonghornDisk {
                        Stepper(value: $dataDiskGB, in: 5...max(5, freeDisk - systemDiskGB - 10), step: 5) {
                            HStack {
                                Text("Longhorn Disk")
                                Spacer()
                                Text("\(dataDiskGB) GB")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                Section("Networking") {
                    Picker("Mode", selection: $selectedNetworkMode) {
                        ForEach(VMNetworkMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if selectedNetworkMode == .bridge {
                        Picker("Bridge Interface", selection: $selectedBridgeName) {
                            ForEach(interfaces, id: \.bsdName) { iface in
                                Text("\(iface.name) [\(iface.bsdName)]").tag(iface.bsdName)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Deploy Node")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .disabled(isDeploying)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        deploy()
                    } label: {
                        if isDeploying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Deploy")
                        }
                    }
                    .disabled(isDeploying)
                }
            }
        }
        .frame(width: 480, height: 560)
        .onAppear {
            if vmName.isEmpty { vmName = "node-\(Int.random(in: 100...999))" }
            if selectedBridgeName.isEmpty, let first = interfaces.first {
                selectedBridgeName = first.bsdName
            }
        }
        .alert("Deploy failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func deploy() {
        isDeploying = true
        Task {
            do {
                let vm = try await VMManager.shared.createLinuxVM(
                    name: vmName,
                    cpus: cpuCount,
                    ramGB: memoryGB,
                    sysDiskGB: systemDiskGB,
                    dataDiskGB: useDedicatedLonghornDisk ? dataDiskGB : 0,
                    isMaster: isMaster,
                    distro: selectedDistro
                )
                
                vm.networkMode = selectedNetworkMode
                vm.bridgeInterfaceName = selectedNetworkMode == .bridge ? selectedBridgeName : nil
                
                isDeploying = false
                isPresented = false
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
