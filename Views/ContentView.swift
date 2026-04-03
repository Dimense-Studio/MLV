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
    static var iso: UTType { UTType(filenameExtension: "iso") ?? .data }
}

enum DashboardPalette {
    static let surface = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let panel = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let panelAlt = Color(red: 0.08, green: 0.09, blue: 0.13)
    static let border = Color.white.opacity(0.07)
    static let textSecondary = Color.white.opacity(0.62)
    static let accentPurple = Color(red: 0.58, green: 0.33, blue: 0.90)
    static let accentCyan = Color(red: 0.15, green: 0.72, blue: 0.82)
    static let accentGreen = Color(red: 0.09, green: 0.78, blue: 0.52)
}

struct DashboardPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(DashboardPalette.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DashboardPalette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct DashboardMetricTile: View {
    let icon: String
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Text(title)
                    .foregroundStyle(DashboardPalette.textSecondary)
                    .font(.system(size: 13, weight: .medium))
            }
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
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
            .scrollContentBackground(.hidden)
            .background(DashboardPalette.surface)
        } detail: {
            Group {
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
            .animation(.easeInOut(duration: 0.22), value: selectedTab)
            .background(
                LinearGradient(
                    colors: [DashboardPalette.surface, Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .background(
            LinearGradient(
                colors: [Color.black, DashboardPalette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenVMConsoleWindow"))) { note in
            if let id = note.object as? UUID {
                openWindow(id: "console", value: id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

#if canImport(__Nonexistent__)
#endif

struct VMListView: View {
    @State private var showingConfigForm = false
    @State private var editingVM: VirtualMachine? = nil
    @State private var search: String = ""
    @State private var viewModel = VMListViewModel()
    
    var body: some View {
        let snapshot = viewModel.snapshot(search: search)
        
        return ZStack(alignment: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(snapshot.allOperational ? DashboardPalette.accentGreen : Color.orange)
                                .frame(width: 11, height: 11)
                            Text(snapshot.allOperational ? "All systems operational" : "Cluster needs attention")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(DashboardPalette.panel)

                        HStack(spacing: 0) {
                            DashboardMetricTile(icon: "cpu", title: "CPU", value: "\(snapshot.averageCPUUsage)%", accent: DashboardPalette.accentPurple)
                            Divider().opacity(0.07)
                            DashboardMetricTile(icon: "memorychip", title: "Memory", value: "\(snapshot.averageMemoryUsage)%", accent: DashboardPalette.accentPurple)
                            Divider().opacity(0.07)
                            DashboardMetricTile(icon: "server.rack", title: "Nodes", value: "\(snapshot.all.count)", accent: DashboardPalette.accentPurple)
                            Divider().opacity(0.07)
                            DashboardMetricTile(icon: "play.circle", title: "Running", value: "\(snapshot.runningCount)", accent: DashboardPalette.accentPurple)
                        }
                        .frame(height: 124)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.44))

                        VStack(spacing: 12) {
                            if snapshot.filtered.isEmpty {
                                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("NO DEPLOYMENTS"))
                                    .padding(.vertical, 36)
                            } else {
                                ForEach(snapshot.filtered) { vm in
                                    VMRowCompact(vm: vm, onDoubleClick: { vm in
                                        NSApp.activate(ignoringOtherApps: true)
                                        NotificationCenter.default.post(name: Notification.Name("OpenVMConsoleWindow"), object: vm.id)
                                    }, onEdit: { vm in
                                        editingVM = vm
                                        showingConfigForm = true
                                    })
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.black.opacity(0.62))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(16)
                .padding(.trailing, showingConfigForm ? 460 : 0)
                .animation(.easeInOut(duration: 0.22), value: showingConfigForm)
            }
            .scrollIndicators(.hidden)

            if showingConfigForm {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingConfigForm = false
                        editingVM = nil
                    }
                    .transition(.opacity)
            }

            if showingConfigForm {
                VMConfigForm(isPresented: $showingConfigForm, vmToEdit: editingVM, presentationStyle: .drawer)
                    .frame(width: 440)
                    .frame(maxHeight: .infinity)
                    .shadow(color: Color.black.opacity(0.35), radius: 24, x: -8, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(DashboardPalette.surface)
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editingVM = nil
                    showingConfigForm = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Add Node")
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
    let onDoubleClick: ((VirtualMachine) -> Void)?
    let onEdit: ((VirtualMachine) -> Void)?
    
    init(vm: VirtualMachine, onDoubleClick: ((VirtualMachine) -> Void)? = nil, onEdit: ((VirtualMachine) -> Void)? = nil) {
        self.vm = vm
        self.onDoubleClick = onDoubleClick
        self.onEdit = onEdit
    }
    
    @State private var showContextDeleteConfirm = false
    
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.system(size: 20, weight: .medium))
                        .lineLimit(1)

                    if vm.isMaster {
                        Text("Master")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }

                    Text(vm.selectedDistro.shortLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(vm.ipAddress)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 18) {
                VMUsageMeter(label: "CPU", value: vm.liveCPUUsagePercent, tint: DashboardPalette.accentPurple, estimated: vm.cpuUsageIsEstimated)
                VMUsageMeter(label: "MEM", value: vm.liveMemoryUsagePercent, tint: DashboardPalette.accentCyan, estimated: vm.memoryUsageIsEstimated)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(Color.black.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.03), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(count: 2) {
            if vm.state.isRunning {
                onDoubleClick?(vm)
            }
        }
        .contextMenu {
            Button {
                onEdit?(vm)
            } label: { Label("Edit VM", systemImage: "slider.horizontal.3") }
            Divider()
            if vm.state == .stopped {
                Button {
                    Task { try? await VMManager.shared.startVM(vm) }
                } label: { Label("Start", systemImage: "play.fill") }
            } else {
                Button {
                    Task { try? await VMManager.shared.stopVM(vm) }
                } label: { Label("Stop", systemImage: "power") }
                Button {
                    Task { try? await VMManager.shared.restartVM(vm) }
                } label: { Label("Restart", systemImage: "arrow.clockwise") }
            }
            Divider()
            Button {
                VMManager.shared.openVMFolder(vm)
            } label: { Label("Open Files", systemImage: "folder") }
            Divider()
            Toggle(isOn: Binding(get: { vm.autoStartOnLaunch }, set: { vm.autoStartOnLaunch = $0 })) {
                Label("Autostart", systemImage: "bolt")
            }
            Divider()
            Button(role: .destructive) {
                showContextDeleteConfirm = true
            } label: { Label("Delete VM and Disks…", systemImage: "trash") }
        }
        .confirmationDialog(
            "Delete \(vm.name)?",
            isPresented: $showContextDeleteConfirm
        ) {
            Button("Delete VM and all Disks", role: .destructive) {
                VMManager.shared.removeVM(vm)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete the virtual machine and all associated disk images !")
        }
    }

    private var statusDotColor: Color {
        switch vm.state {
        case .running:
            return DashboardPalette.accentGreen
        case .starting:
            return .yellow
        case .error:
            return .red
        case .paused:
            return .orange
        case .stopped:
            return .gray
        }
    }
}

private struct VMUsageMeter: View {
    let label: String
    let value: Int
    let tint: Color
    let estimated: Bool

    var body: some View {
        let isAvailable = value >= 0
        let safeValue = max(0, value)
        HStack(spacing: 8) {
            Text(estimated ? "\(label)~" : label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.textSecondary)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 130, height: 8)
                Capsule()
                    .fill(isAvailable ? tint : Color.white.opacity(0.18))
                    .frame(width: isAvailable ? max(8, 130 * CGFloat(min(max(safeValue, 0), 100)) / 100) : 0, height: 8)
            }
            Text(isAvailable ? "\(safeValue)%" : "--")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DashboardPalette.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private extension VirtualMachine {
    var liveCPUUsagePercent: Int {
        guard state.isRunning else { return 0 }
        return hasGuestUsageSample ? guestCPUUsagePercent : -1
    }

    var liveMemoryUsagePercent: Int {
        guard state.isRunning else { return 0 }
        return hasGuestUsageSample ? guestMemoryUsagePercent : -1
    }

    var cpuUsageIsEstimated: Bool {
        state.isRunning && !hasGuestUsageSample && !isInstalled
    }

    var memoryUsageIsEstimated: Bool {
        state.isRunning && !hasGuestUsageSample && !isInstalled
    }

}

struct VMInspector: View {
    let vm: VirtualMachine
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        ContentUnavailableView("Controls Moved", systemImage: "cursorarrow.click", description: Text("Use right-click on a VM to manage it."))
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
                Text("Use right-click on the VM in the list to control it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .background(
            DarkGlassBackground(cornerRadius: 16)
        )
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
                            if vm.pods.isEmpty && vm.containers.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Detecting workloads…")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !vm.pods.isEmpty {
                                Text("Kubernetes Pods")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(vm.pods) { pod in
                                    PodRow(name: pod.name, status: pod.status, cpu: pod.cpu, ram: pod.ram, namespace: pod.namespace)
                                }
                            }

                            if !vm.containers.isEmpty {
                                Text("Docker Containers")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, vm.pods.isEmpty ? 0 : 8)
                                ForEach(vm.containers) { container in
                                    ContainerRow(
                                        name: container.name,
                                        image: container.image,
                                        status: container.status,
                                        runtime: container.runtime
                                    )
                                }
                            }
                        } header: {
                            HStack {
                                Text(vm.name)
                                Spacer()
                                StatusBadge(state: vm.state)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(DashboardPalette.surface)
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
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(DashboardPalette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct ContainerRow: View {
    let name: String
    let image: String
    let status: String
    let runtime: String

    private var statusColor: Color {
        if status.localizedCaseInsensitiveContains("up") || status.localizedCaseInsensitiveContains("running") {
            return .green
        }
        if status.localizedCaseInsensitiveContains("created") || status.localizedCaseInsensitiveContains("restarting") {
            return .orange
        }
        return .red
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Text("\(runtime) • \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(image)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(DashboardPalette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(DashboardPalette.surface)
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
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(DashboardPalette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                
                LabeledContent("Listen Port") {
                    Text("\(WireGuardManager.shared.listenPort)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                
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
        .scrollContentBackground(.hidden)
        .background(DashboardPalette.surface)
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

#if false
struct LegacyVMConfigForm: View {
    @Environment(\.dismiss) private var dismiss
    
    enum PresentationStyle {
        case sheet
        case drawer
    }
    
    @Binding var isPresented: Bool
    let vmToEdit: VirtualMachine?
    var presentationStyle: PresentationStyle = .sheet
    
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
    @State private var enableSecondaryNetwork: Bool = false
    @State private var secondaryNetworkMode: VMNetworkMode = .nat
    @State private var secondaryBridgeName: String = ""
    
    // Real Host Limits
    private let maxCores = max(1, HostResources.cpuCount - 2)
    private let maxRAM = max(2, HostResources.totalMemoryGB - 2)
    private let freeDisk = HostResources.freeDiskSpaceGB
    private let interfaces = HostResources.getNetworkInterfaces()
    private var isEditing: Bool { vmToEdit != nil }
    private var primaryActionTitle: String { isEditing ? "Save" : "Deploy" }
    
    var body: some View {
        Group {
            if presentationStyle == .sheet {
                NavigationStack {
                    formContent
                        .navigationTitle(isEditing ? "Edit Node" : "Deploy Node")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { closeForm() }
                                    .disabled(isDeploying)
                            }
                            ToolbarItem(placement: .primaryAction) {
                                primaryActionButton
                            }
                        }
                }
                .frame(width: 520, height: 600)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 8, height: 8)
                        Text(isEditing ? "Edit Node" : "Deploy Node")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Button {
                            closeForm()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isDeploying)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.28))

                    formContent

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    HStack(spacing: 10) {
                        Button("Cancel") {
                            closeForm()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(isDeploying)

                        Spacer()

                        primaryActionButton
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.24))
                }
                .background(
                    LinearGradient(
                        colors: [DashboardPalette.panelAlt, Color.black.opacity(0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1)
                }
            }
        }
        .onAppear {
            if let vm = vmToEdit {
                vmName = vm.name
                cpuCount = vm.cpuCount
                memoryGB = vm.memorySizeGB
                systemDiskGB = vm.systemDiskSizeGB
                dataDiskGB = vm.dataDiskSizeGB
                useDedicatedLonghornDisk = vm.dataDiskSizeGB > 0
                isMaster = vm.isMaster
                selectedDistro = vm.selectedDistro
                selectedNetworkMode = vm.networkMode
                selectedBridgeName = vm.bridgeInterfaceName ?? selectedBridgeName
                enableSecondaryNetwork = vm.secondaryNetworkEnabled
                secondaryNetworkMode = vm.secondaryNetworkMode
                secondaryBridgeName = vm.secondaryBridgeInterfaceName ?? secondaryBridgeName
            } else if vmName.isEmpty {
                vmName = "node-\(Int.random(in: 100...999))"
            }
            if selectedBridgeName.isEmpty, let first = interfaces.first {
                selectedBridgeName = first.bsdName
            }
            if secondaryBridgeName.isEmpty, let first = interfaces.first {
                secondaryBridgeName = first.bsdName
            }
        }
        .alert(isEditing ? "Save failed" : "Deploy failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Identity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        TextField("Node Name", text: $vmName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(isEditing)
                        Picker("Role", selection: $isMaster) {
                            Text("Worker").tag(false)
                            Text("Master").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Distribution")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        Picker("Linux", selection: $selectedDistro) {
                            ForEach(VirtualMachine.LinuxDistro.allCases) { distro in
                                Text(distro.rawValue).tag(distro)
                            }
                        }
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Resources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        Stepper(value: $cpuCount, in: 1...HostResources.cpuCount, step: 1) {
                            HStack {
                                Text("CPU")
                                Spacer()
                                Text("\(cpuCount)")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(cpuCount > maxCores ? Color.red : DashboardPalette.textSecondary)
                            }
                        }
                        CapacityBar(title: "Host CPU Budget", used: cpuCount, total: HostResources.cpuCount)
                        Stepper(value: $memoryGB, in: 2...HostResources.totalMemoryGB, step: 2) {
                            HStack {
                                Text("RAM")
                                Spacer()
                                Text("\(memoryGB) GB")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(memoryGB > maxRAM ? Color.red : DashboardPalette.textSecondary)
                            }
                        }
                        CapacityBar(title: "Host RAM Budget", used: memoryGB, total: HostResources.totalMemoryGB)
                        Stepper(value: $systemDiskGB, in: 5...200, step: 5) {
                            HStack {
                                Text("System Disk")
                                Spacer()
                                Text("\(systemDiskGB) GB")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(DashboardPalette.textSecondary)
                            }
                        }
                        CapacityBar(title: "Estimated Host Disk", used: systemDiskGB + (useDedicatedLonghornDisk ? dataDiskGB : 0), total: max(1, freeDisk))
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Storage")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        Toggle("Dedicated Longhorn Disk", isOn: $useDedicatedLonghornDisk)
                        if useDedicatedLonghornDisk {
                            let maxData = max(5, freeDisk - systemDiskGB - 10)
                            Stepper(value: $dataDiskGB, in: 5...maxData, step: 5) {
                                HStack {
                                    Text("Longhorn Disk")
                                    Spacer()
                                    Text("\(dataDiskGB) GB")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle((systemDiskGB + dataDiskGB) > freeDisk ? Color.red : DashboardPalette.textSecondary)
                                }
                            }
                            CapacityBar(title: "Storage Pressure", used: systemDiskGB + dataDiskGB, total: max(1, freeDisk))
                        }
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Networking")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
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
                        Toggle("Enable Secondary Interface", isOn: $enableSecondaryNetwork)
                        if enableSecondaryNetwork {
                            Picker("Secondary Mode", selection: $secondaryNetworkMode) {
                                ForEach(VMNetworkMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            if secondaryNetworkMode == .bridge {
                                Picker("Secondary Bridge", selection: $secondaryBridgeName) {
                                    ForEach(interfaces, id: \.bsdName) { iface in
                                        Text("\(iface.name) [\(iface.bsdName)]").tag(iface.bsdName)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [DashboardPalette.surface, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var primaryActionButton: some View {
        Button {
            submit()
        } label: {
            if isDeploying {
                ProgressView().controlSize(.small)
            } else {
                Text(primaryActionTitle)
            }
        }
        .disabled(isDeploying)
    }
    
    private func closeForm() {
        isPresented = false
        if presentationStyle == .sheet {
            dismiss()
        }
    }

    private func submit() {
        isDeploying = true
        Task {
            do {
                if let vm = vmToEdit {
                    vm.cpuCount = cpuCount
                    vm.memorySizeGB = memoryGB
                    if vm.state == .stopped {
                        vm.systemDiskSizeGB = systemDiskGB
                        vm.dataDiskSizeGB = useDedicatedLonghornDisk ? dataDiskGB : 0
                    }
                    vm.isMaster = isMaster
                    vm.selectedDistro = selectedDistro
                    vm.networkMode = selectedNetworkMode
                    vm.bridgeInterfaceName = selectedNetworkMode == .bridge ? selectedBridgeName : nil
                    vm.secondaryNetworkEnabled = enableSecondaryNetwork
                    vm.secondaryNetworkMode = secondaryNetworkMode
                    vm.secondaryBridgeInterfaceName = (enableSecondaryNetwork && secondaryNetworkMode == .bridge) ? secondaryBridgeName : nil
                    vm.monitoredProcessName = "mlv-" + vm.name
                        .lowercased()
                        .replacingOccurrences(of: " ", with: "-")
                        .replacingOccurrences(of: "_", with: "-")
                    vm.persist()
                    isDeploying = false
                    closeForm()
                    return
                }

                _ = try await VMManager.shared.createLinuxVM(
                    name: vmName,
                    cpus: cpuCount,
                    ramGB: memoryGB,
                    sysDiskGB: systemDiskGB,
                    dataDiskGB: useDedicatedLonghornDisk ? dataDiskGB : 0,
                    isMaster: isMaster,
                    distro: selectedDistro,
                    networkMode: selectedNetworkMode,
                    bridgeInterfaceName: selectedBridgeName,
                    secondaryNetworkEnabled: enableSecondaryNetwork,
                    secondaryNetworkMode: secondaryNetworkMode,
                    secondaryBridgeInterfaceName: secondaryBridgeName
                )
                
                isDeploying = false
                closeForm()
            } catch {
                errorMessage = error.localizedDescription
                isDeploying = false
            }
        }
    }
}

struct LegacyCapacityBar: View {
    
    let title: String
    let used: Int
    let total: Int

    private var ratio: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }

    private var barColor: Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.75 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(used)/\(total)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, geo.size.width * ratio))
                }
            }
            .frame(height: 8)
        }
    }
}

struct LegacyDistroCard: View {
    
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

struct LegacyRoleButtonMinimal: View {
    
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

struct LegacyRoleButton: View {
    
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

struct LegacyConfigSlider: View {
    
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
#endif
