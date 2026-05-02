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
    static let surface: Color = .clear
    static let panel = OverlayTheme.panel
    static let panelAlt = OverlayTheme.panelStrong
    static let border = OverlayTheme.border
    static let textSecondary = OverlayTheme.textSecondary
    static let accentPrimary = Color.white.opacity(0.84)
    static let accentSecondary = Color.white.opacity(0.68)
    static let accentTertiary = Color.white.opacity(0.56)
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
    @State private var settings = AppSettingsStore.shared
    
    private var isContainerMode: Bool {
        settings.workloadRuntime == .appleContainer
    }
    
    enum ClusterTab: String, CaseIterable {
        case vms = "Virtual Machines"
        case pods = "Kubernetes Pods"
        case storage = "Distributed Storage"
        case network = "Network Topology"
        case images = "Images"
        case talosSetup = "Talos Setup"

        var icon: String {
            switch self {
            case .vms: return "macwindow"
            case .pods: return "shippingbox.fill"
            case .storage: return "externaldrive.connected.to.line.below"
            case .network: return "network"
            case .images: return "square.stack.3d.up"
            case .talosSetup: return "gear.badge.checkmark"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                OverlayCanvasBackground()
                Group {
                    switch selectedTab {
                    case .vms:
                        VMListView(search: searchText)
                            .navigationTitle(isContainerMode ? "Containers" : "Virtual Machines")
                    case .pods:
                        PodsListView(search: searchText)
                            .navigationTitle("Kubernetes Pods")
                    case .storage:
                        StorageListView(search: searchText)
                            .navigationTitle("Distributed Storage")
                    case .network:
                        NetworkListView(search: searchText)
                            .navigationTitle("Network Topology")
                    case .images:
                        ImagesRepositoryView(search: searchText)
                            .navigationTitle("Container Images")
                    case .talosSetup:
                        TalosSetupView(search: searchText)
                            .navigationTitle("Talos Setup")
                    }
                }
                .padding(.leading, 64)
                .padding(.top, 14)

                OverlaySidebar(
                    selectedTab: $selectedTab,
                    isContainerMode: isContainerMode
                )
                .padding(.top, 27)
                .padding(.leading, 10)
            }
            .searchable(text: $searchText)
            .animation(.easeInOut(duration: 0.22), value: selectedTab)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        settings.workloadRuntime = settings.workloadRuntime == .appleContainer ? .virtualization : .appleContainer
                    } label: {
                        Label(
                            settings.workloadRuntime == .appleContainer ? "Container Mode" : "VM Mode",
                            systemImage: settings.workloadRuntime == .appleContainer ? "shippingbox.fill" : "macwindow"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(settings.workloadRuntime == .appleContainer ? Color.blue.opacity(0.9) : OverlayTheme.textSecondary)
                    }
                    .help("Switch Runtime")
                }
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
        .onChange(of: searchText) { _, newValue in
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            guard !tabContainsMatch(selectedTab, query: query) else { return }
            if let matchingTab = ClusterTab.allCases.first(where: { tabContainsMatch($0, query: query) }) {
                selectedTab = matchingTab
            }
        }
    }

    private func tabContainsMatch(_ tab: ClusterTab, query: String) -> Bool {
        if tab.rawValue.localizedCaseInsensitiveContains(query) {
            return true
        }
        let allVMs = VMManager.shared.virtualMachines
        switch tab {
        case .vms:
            return allVMs.contains { vm in
                vm.name.localizedCaseInsensitiveContains(query)
            }
        case .pods:
            let running = allVMs.filter { $0.state == .running }
            return running.contains { vm in
                vm.name.localizedCaseInsensitiveContains(query) ||
                vm.pods.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.namespace.localizedCaseInsensitiveContains(query) ||
                    $0.status.localizedCaseInsensitiveContains(query) ||
                    $0.cpu.localizedCaseInsensitiveContains(query) ||
                    $0.ram.localizedCaseInsensitiveContains(query)
                }) ||
                vm.containers.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.image.localizedCaseInsensitiveContains(query) ||
                    $0.status.localizedCaseInsensitiveContains(query) ||
                    $0.runtime.localizedCaseInsensitiveContains(query)
                })
            }
        case .storage:
            return allVMs.contains { vm in
                vm.name.localizedCaseInsensitiveContains(query) ||
                "system.img".localizedCaseInsensitiveContains(query) ||
                "data.img".localizedCaseInsensitiveContains(query) ||
                "OS & Boot".localizedCaseInsensitiveContains(query) ||
                "Longhorn Block Storage".localizedCaseInsensitiveContains(query)
            }
        case .network:
            if WireGuardManager.shared.hostInfo.name.localizedCaseInsensitiveContains(query) ||
                WireGuardManager.shared.publicKeyShort.localizedCaseInsensitiveContains(query) {
                return true
            }
            if DiscoveryManager.shared.discovered.contains(where: { host in
                host.name.localizedCaseInsensitiveContains(query) ||
                host.addressCIDR.localizedCaseInsensitiveContains(query) ||
                (DiscoveryManager.shared.pairStatusByID[host.id] ?? "").localizedCaseInsensitiveContains(query)
            }) {
                return true
            }
            if WireGuardManager.shared.peers.contains(where: { peer in
                peer.name.localizedCaseInsensitiveContains(query) ||
                peer.addressCIDR.localizedCaseInsensitiveContains(query)
            }) {
                return true
            }
            return allVMs.contains { vm in
                vm.name.localizedCaseInsensitiveContains(query) ||
                vm.networkMode.rawValue.localizedCaseInsensitiveContains(query) ||
                vm.ipAddress.localizedCaseInsensitiveContains(query) ||
                vm.gateway.localizedCaseInsensitiveContains(query) ||
                (vm.bridgeInterfaceName ?? "").localizedCaseInsensitiveContains(query)
            }
        case .images:
            guard isContainerMode else { return false }
            return query.localizedCaseInsensitiveContains("image") || query.localizedCaseInsensitiveContains("container")
        case .talosSetup:
            return query.localizedCaseInsensitiveContains("talos") ||
                query.localizedCaseInsensitiveContains("setup") ||
                query.localizedCaseInsensitiveContains("config") ||
                query.localizedCaseInsensitiveContains("auto")
        }
    }
}

private struct OverlaySidebar: View {
    @Binding var selectedTab: ContentView.ClusterTab
    let isContainerMode: Bool
    
    private var visibleTabs: [ContentView.ClusterTab] {
        if isContainerMode {
            return [.vms, .pods, .storage, .network, .images, .talosSetup]
        }
        return [.vms, .pods, .storage, .network, .talosSetup]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selectedTab == tab ? OverlayTheme.textPrimary : OverlayTheme.textSecondary)
                            .frame(width: 34, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTab == tab ? OverlayTheme.panelStrong : OverlayTheme.panel)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(OverlayTheme.border.opacity(selectedTab == tab ? 1.0 : 0.75), lineWidth: 1)
                            )
                            .overlay(alignment: .leading) {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(OverlayTheme.accent)
                                        .frame(width: 3, height: 26)
                                        .transition(.move(edge: .leading).combined(with: .opacity))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(tab == .vms ? (isContainerMode ? "Containers" : "Virtual Machines") : tab.rawValue)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OverlayTheme.panel.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OverlayTheme.border.opacity(0.55), lineWidth: 1)
        )
    }
}

#if canImport(__Nonexistent__)
#endif

struct VMListView: View {
    @State private var showingConfigForm = false
    @State private var editingVM: VirtualMachine? = nil
    let search: String
    @State private var viewModel = VMListViewModel()
    
    private var isContainerMode: Bool {
        AppSettingsStore.shared.workloadRuntime == .appleContainer
    }
    
    var body: some View {
        let snapshot = viewModel.snapshot(search: search, isContainerMode: isContainerMode)
        
        return ZStack(alignment: .trailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(snapshot.allOperational ? DashboardPalette.accentPrimary : DashboardPalette.accentTertiary)
                                .frame(width: 11, height: 11)
                            Text(snapshot.allOperational ? "All systems operational" : "Cluster needs attention")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)

                        HStack(spacing: 0) {
                            DashboardMetricTile(icon: "cpu", title: "CPU", value: "\(snapshot.averageCPUUsage)%", accent: DashboardPalette.accentPrimary)
                            Divider().opacity(0.07)
                            DashboardMetricTile(icon: "memorychip", title: "Memory", value: "\(snapshot.averageMemoryUsage)%", accent: DashboardPalette.accentSecondary)
                            Divider().opacity(0.07)
                            let totalNodes = snapshot.all.count + snapshot.remoteVMs.count
                            DashboardMetricTile(icon: "server.rack", title: isContainerMode ? "Containers" : "Nodes", value: "\(totalNodes)", accent: DashboardPalette.accentTertiary)
                            Divider().opacity(0.07)
                            DashboardMetricTile(icon: "play.circle", title: "Running", value: "\(snapshot.runningCount)", accent: DashboardPalette.accentSecondary)
                        }
                        .frame(height: 124)
                        .padding(.vertical, 6)
                    }
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(OverlayTheme.panelStrong.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(DashboardPalette.border.opacity(0.75), lineWidth: 1)
                    )

                    LazyVStack(spacing: 16) {
                        // Local VMs section
                        if !snapshot.filtered.isEmpty {
                            ForEach(snapshot.filtered) { vm in
                                VMRowCompact(vm: vm, onDoubleClick: { vm in
                                    if isContainerMode {
                                        openContainerIP(vm)
                                        return
                                    }
                                    NSApp.activate(ignoringOtherApps: true)
                                    NotificationCenter.default.post(name: Notification.Name("OpenVMConsoleWindow"), object: vm.id)
                                }, onEdit: { vm in
                                    editingVM = vm
                                    showingConfigForm = true
                                })
                                .onTapGesture {
                                    if isContainerMode {
                                        openContainerIP(vm)
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                        }

                        // Remote VMs from paired nodes section
                        if !snapshot.filteredRemoteVMs.isEmpty {
                            HStack {
                                Image(systemName: "network")
                                    .foregroundStyle(.secondary)
                                Text("Remote Nodes (\(snapshot.pairedNodeCount) paired)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                            ForEach(snapshot.filteredRemoteVMs) { remoteVM in
                                RemoteVMRow(vm: remoteVM)
                                    .padding(.horizontal, 4)
                            }
                        }

                        // No results case
                        if snapshot.filtered.isEmpty && snapshot.filteredRemoteVMs.isEmpty {
                            ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No local or remote deployments match your search"))
                                .padding(.vertical, 36)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
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
                .help(isContainerMode ? "Add Container" : "Add Node")
            }
        }
    }

    private func openContainerIP(_ vm: VirtualMachine) {
        let ip = vm.ipAddress
        if ip != "Detecting..." && !ip.isEmpty {
            if let url = URL(string: "http://\(ip)") {
                NSWorkspace.shared.open(url)
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
    
    private var isContainerMode: Bool {
        AppSettingsStore.shared.workloadRuntime == .appleContainer
    }
    
    var body: some View {
        let cardGradient = LinearGradient(
            colors: isContainerMode
                ? [Color.blue.opacity(0.20), Color.cyan.opacity(0.12)]
                : [Color.purple.opacity(0.20), Color.indigo.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        HStack(spacing: 14) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.system(size: 20, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(isContainerMode && vm.state.isRunning ? .blue.opacity(0.9) : .primary)

                    if vm.isMaster {
                        Text("Master")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }

                    if !isContainerMode {
                        Text(vm.selectedDistro.shortLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 4) {
                    if isContainerMode && vm.state.isRunning {
                        Image(systemName: "safari")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Text(vm.ipAddress)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isContainerMode && vm.state.isRunning && vm.ipAddress != "Detecting..." ? .blue.opacity(0.8) : .secondary)
                        .lineLimit(1)
                    if let pid = vm.hostServicePID {
                        Text("PID \(pid)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 18) {
                VMUsageMeter(label: "CPU", value: vm.liveCPUUsagePercent, tint: DashboardPalette.accentPrimary, estimated: vm.cpuUsageIsEstimated)
                VMUsageMeter(label: "MEM", value: vm.liveMemoryUsagePercent, tint: DashboardPalette.accentSecondary, estimated: vm.memoryUsageIsEstimated)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            cardGradient
                .blendMode(.screen)
        )
        .background(OverlayTheme.panelStrong)
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
            } label: { Label(isContainerMode ? "Edit Container" : "Edit VM", systemImage: "slider.horizontal.3") }
            Divider()
            if vm.state == .stopped {
                Button {
                    Task { try? await VMManager.shared.startVM(vm) }
                } label: { Label(isContainerMode ? "Start Container" : "Start", systemImage: "play.fill") }
            } else {
                Button {
                    Task { try? await VMManager.shared.stopVM(vm) }
                } label: { Label(isContainerMode ? "Stop Container" : "Stop", systemImage: "power") }
                Button {
                    Task { try? await VMManager.shared.restartVM(vm) }
                } label: { Label(isContainerMode ? "Restart Container" : "Restart", systemImage: "arrow.clockwise") }
            }
            Divider()
            Button {
                VMManager.shared.openVMFolder(vm)
            } label: { Label("Open Files", systemImage: "folder") }
            if vm.selectedDistro == .talos && vm.state.isRunning {
                Button {
                    TalosAutoSetupService.shared.checkForTalosUpdate(for: vm)
                } label: { Label("Check for Talos Update", systemImage: "arrow.up.circle") }
            }
            Divider()
            Toggle(isOn: Binding(get: { vm.autoStartOnLaunch }, set: { vm.autoStartOnLaunch = $0 })) {
                Label("Autostart", systemImage: "bolt")
            }
            Divider()
            Button(role: .destructive) {
                showContextDeleteConfirm = true
            } label: { Label(isContainerMode ? "Delete Container Workload…" : "Delete VM and Disks…", systemImage: "trash") }
        }
        .confirmationDialog(
            "Delete \(vm.name)?",
            isPresented: $showContextDeleteConfirm
        ) {
            Button(isContainerMode ? "Delete Container Workload" : "Delete VM and all Disks", role: .destructive) {
                VMManager.shared.removeVM(vm)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(isContainerMode
                 ? "This will permanently delete the container workload from Apple container runtime."
                 : "This will permanently delete the virtual machine and all associated disk images !")
        }
    }

    private var statusDotColor: Color {
        switch vm.state {
        case .running:
            return .green
        case .starting:
            return .yellow
        case .error:
            return .red
        case .paused:
            return .yellow
        case .stopped:
            return .gray
        }
    }
}

// MARK: - Remote VM Row (for VMs from paired nodes)

struct RemoteVMRow: View {
    let vm: ClusterManager.GlobalVMInfo

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.cyan)
                .frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vm.name)
                        .font(.system(size: 20, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Text("Remote")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.15), in: Capsule())

                    if vm.isMaster {
                        Text("Master")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(vm.primaryAddress ?? vm.wgAddress)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("via \(vm.hostEndpoint):\(vm.hostPort)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }

            Spacer()

            // No usage meters for remote VMs (data not available via RPC)
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("Remote")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            LinearGradient(
                colors: [Color.cyan.opacity(0.10), Color.blue.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.screen)
        )
        .background(OverlayTheme.panelStrong)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
    @State private var settings = AppSettingsStore.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(Color.white.opacity(0.84))
                        Text(vm.name)
                            .font(.system(.headline, design: .rounded))
                        
                        if vm.isMaster {
                            Text("MASTER")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(AnyShapeStyle(Color.white.opacity(0.18)))
                                .foregroundStyle(AnyShapeStyle(Color.white.opacity(0.88)))
                                .cornerRadius(4)
                        }

                        if !settings.workloadRuntime.isContainer {
                            Text(vm.selectedDistro.shortLabel.uppercased())
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.08))
                                .foregroundStyle(AnyShapeStyle(.secondary.opacity(0.8)))
                                .cornerRadius(4)
                        }
                        
                        Text(vm.stage.rawValue.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.10))
                            .foregroundStyle(AnyShapeStyle(Color.white.opacity(0.84)))
                            .cornerRadius(4)
                    }
                    Text(settings.workloadRuntime.isContainer ? (vm.containerImageReference.isEmpty ? "No image specified" : vm.containerImageReference) : (vm.isInstalled ? vm.selectedDistro.rawValue : "Provisioning System..."))
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
                Label("\(vm.memorySizeMB / 1024) GB RAM", systemImage: "bolt.fill")
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
                .foregroundStyle(AnyShapeStyle(Color.white.opacity(0.82)))
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
    let search: String

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = VMManager.shared.virtualMachines.filter { $0.state == .running }
        let filteredRunning = running.filter { vm in
            guard !query.isEmpty else { return true }
            return vm.name.localizedCaseInsensitiveContains(query) ||
                vm.pods.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.namespace.localizedCaseInsensitiveContains(query) ||
                    $0.status.localizedCaseInsensitiveContains(query) ||
                    $0.cpu.localizedCaseInsensitiveContains(query) ||
                    $0.ram.localizedCaseInsensitiveContains(query)
                }) ||
                vm.containers.contains(where: {
                    $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.image.localizedCaseInsensitiveContains(query) ||
                    $0.status.localizedCaseInsensitiveContains(query) ||
                    $0.runtime.localizedCaseInsensitiveContains(query)
                })
        }
        
        return Group {
            if running.isEmpty {
                ContentUnavailableView("No Running Nodes", systemImage: "bolt.horizontal.circle", description: Text("Deploy and start a Linux node to see active Kubernetes pods"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filteredRunning.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No pods or containers match your search"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Combined mesh + list inspired by OpenShift circles
                        ContainerMeshView(vms: filteredRunning)
                            .frame(height: 300)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(DashboardPalette.panel.opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(DashboardPalette.border.opacity(0.55), lineWidth: 0.8)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16))

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredRunning) { vm in
                                let showAllForVM = query.isEmpty || vm.name.localizedCaseInsensitiveContains(query)
                                let visiblePods = showAllForVM ? vm.pods : vm.pods.filter {
                                    $0.name.localizedCaseInsensitiveContains(query) ||
                                    $0.namespace.localizedCaseInsensitiveContains(query) ||
                                    $0.status.localizedCaseInsensitiveContains(query) ||
                                    $0.cpu.localizedCaseInsensitiveContains(query) ||
                                    $0.ram.localizedCaseInsensitiveContains(query)
                                }
                                let visibleContainers = showAllForVM ? vm.containers : vm.containers.filter {
                                    $0.name.localizedCaseInsensitiveContains(query) ||
                                    $0.image.localizedCaseInsensitiveContains(query) ||
                                    $0.status.localizedCaseInsensitiveContains(query) ||
                                    $0.runtime.localizedCaseInsensitiveContains(query)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(vm.name)
                                        let ipLabel = vm.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !ipLabel.isEmpty && !ipLabel.lowercased().contains("detect") {
                                            Text("•")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary.opacity(0.5))
                                            Text(ipLabel)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.blue.opacity(0.8))
                                        } else {
                                            Text("•")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary.opacity(0.25))
                                            Text("IP pending…")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        StatusBadge(state: vm.state)
                                    }

                                    if visiblePods.isEmpty && visibleContainers.isEmpty {
                                        HStack(spacing: 8) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Detecting workloads…")
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if !visiblePods.isEmpty {
                                        Text("Kubernetes Pods")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        ForEach(visiblePods) { pod in
                                            PodRow(name: pod.name, status: pod.status, cpu: pod.cpu, ram: pod.ram, namespace: pod.namespace, vm: vm)
                                        }
                                    }

                                    if !visibleContainers.isEmpty {
                                        Text("Docker Containers")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.top, visiblePods.isEmpty ? 0 : 8)
                                        ForEach(visibleContainers) { container in
                                            ContainerRow(
                                                name: container.name,
                                                image: container.image,
                                                status: container.status,
                                                runtime: container.runtime
                                            )
                                        }
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(OverlayTheme.panelStrong.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(DashboardPalette.border.opacity(0.8), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(12)
                }
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
    let vm: VirtualMachine

    @State private var showLogs = false
    @State private var logContent = ""
    @State private var isLoadingLogs = false
    @State private var actionMessage: String? = nil

    private var statusColor: Color {
        switch status {
        case "Running": return .green
        case "Pending": return .yellow
        case "Succeeded": return .blue
        default: return .red
        }
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
                Text("\(namespace) • \(status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let msg = actionMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }

            Spacer()

            Text("\(cpu) • \(ram)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu {
                Section("Actions") {
                    Button {
                        Task {
                            actionMessage = "Restarting…"
                            let out = await TalosPodMonitor.shared.restartPod(name: name, namespace: namespace, for: vm)
                            actionMessage = out
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { actionMessage = nil }
                        }
                    } label: { Label("Restart", systemImage: "arrow.clockwise") }

                    Button {
                        actionMessage = "Loading logs…"
                        isLoadingLogs = true
                        Task {
                            logContent = await TalosPodMonitor.shared.fetchPodLogs(name: name, namespace: namespace, for: vm)
                            isLoadingLogs = false
                            actionMessage = nil
                            showLogs = true
                        }
                    } label: { Label("View Logs", systemImage: "doc.text") }

                    Button {
                        TalosPodMonitor.shared.execShell(name: name, namespace: namespace, for: vm)
                    } label: { Label("Open Shell", systemImage: "terminal") }
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            actionMessage = "Deleting…"
                            let out = await TalosPodMonitor.shared.deletePod(name: name, namespace: namespace, for: vm)
                            actionMessage = out
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { actionMessage = nil }
                        }
                    } label: { Label("Delete Pod", systemImage: "trash") }
                }
            } label: {
                if isLoadingLogs {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
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
        .sheet(isPresented: $showLogs) {
            PodLogsSheet(podName: name, namespace: namespace, logs: logContent, vm: vm)
        }
    }
}

struct PodLogsSheet: View {
    let podName: String
    let namespace: String
    let logs: String
    let vm: VirtualMachine

    @State private var content: String
    @State private var isRefreshing = false
    @Environment(\.dismiss) private var dismiss

    init(podName: String, namespace: String, logs: String, vm: VirtualMachine) {
        self.podName = podName
        self.namespace = namespace
        self.logs = logs
        self.vm = vm
        _content = State(initialValue: logs)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(podName)
                        .font(.headline)
                    Text(namespace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    isRefreshing = true
                    Task {
                        content = await TalosPodMonitor.shared.fetchPodLogs(name: podName, namespace: namespace, for: vm)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy logs")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            ScrollView {
                ScrollViewReader { proxy in
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                        .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                        .onChange(of: content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .background(Color.black.opacity(0.3))
        }
        .frame(minWidth: 700, minHeight: 500)
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

struct ImagesRepositoryView: View {
    let search: String

    @State private var images: [ContainerImageInfo] = []
    @State private var isLoading = false
    @State private var pullReference: String = ""
    @State private var pendingDelete: ContainerImageInfo? = nil
    @State private var errorMessage: String? = nil
    @State private var isPullingImage = false
    @State private var pullProgress: Double = 0
    @State private var pullProgressDetail: String = ""

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredImages: [ContainerImageInfo] {
        guard !query.isEmpty else { return images }
        return images.filter {
            $0.reference.localizedCaseInsensitiveContains(query) ||
            $0.imageID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DashboardPanel {
                HStack(spacing: 10) {
                    TextField("Pull image (e.g. ubuntu:24.04)", text: $pullReference)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Pull") {
                        pullImage()
                    }
                    .disabled(pullReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    Button("Refresh") {
                        refreshImages()
                    }
                    .disabled(isLoading)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isPullingImage {
                DashboardPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: pullProgress, total: 1.0)
                        HStack {
                            Text("Pulling image...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(pullProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !pullProgressDetail.isEmpty {
                            Text(pullProgressDetail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if isLoading && images.isEmpty {
                ProgressView("Loading container images...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredImages.isEmpty {
                ContentUnavailableView(
                    "No Images",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Pull images with the field above, then manage them here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredImages) { image in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(image.reference)
                                    .font(.system(.body, design: .monospaced))
                                Text(image.imageID.isEmpty ? "id: unknown" : image.imageID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(image.size.isEmpty ? "-" : image.size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                pendingDelete = image
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(16)
        .background(DashboardPalette.surface)
        .onAppear {
            refreshImages()
        }
        .confirmationDialog(
            "Delete image?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let image = pendingDelete {
                Button("Delete \(image.reference)", role: .destructive) {
                    deleteImage(image)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Image will be removed from local Apple container repository.")
        }
    }

    private func refreshImages() {
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            do {
                images = try await VMManager.shared.listContainerImages()
            } catch {
                errorMessage = "Failed to list images: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func pullImage() {
        let reference = pullReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return }
        isLoading = true
        isPullingImage = true
        pullProgress = 0
        pullProgressDetail = ""
        errorMessage = nil
        Task { @MainActor in
            do {
                try await VMManager.shared.pullContainerImage(reference: reference) { progress, detail in
                    pullProgress = max(pullProgress, progress)
                    pullProgressDetail = detail
                }
                pullProgress = 1.0
                pullReference = ""
                images = try await VMManager.shared.listContainerImages()
            } catch {
                errorMessage = "Failed to pull image: \(error.localizedDescription)"
            }
            isPullingImage = false
            isLoading = false
        }
    }

    private func deleteImage(_ image: ContainerImageInfo) {
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            defer {
                pendingDelete = nil
                isLoading = false
            }
            do {
                try await VMManager.shared.deleteContainerImage(reference: image.reference)
                images = try await VMManager.shared.listContainerImages()
            } catch {
                errorMessage = "Failed to delete image: \(error.localizedDescription)"
            }
        }
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
    let search: String

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = VMManager.shared.virtualMachines
        let filtered = all.filter { vm in
            guard !query.isEmpty else { return true }
            return vm.name.localizedCaseInsensitiveContains(query) ||
                "system.img".localizedCaseInsensitiveContains(query) ||
                "data.img".localizedCaseInsensitiveContains(query) ||
                "OS & Boot".localizedCaseInsensitiveContains(query) ||
                "Longhorn Block Storage".localizedCaseInsensitiveContains(query)
        }
        
        return Group {
            if all.isEmpty {
                ContentUnavailableView("No Storage Active", systemImage: "externaldrive.badge.xmark", description: Text("Start a node to see allocated disk space"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filtered.isEmpty {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("No storage entries match your search"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(filtered) { vm in
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
    let search: String
    @State private var selectedNodeID: String? = nil
    @State private var showConfig = false
    @State private var settingsMessage: String?
    @State private var isClusterTestRunning = false
    @State private var clusterTestTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                NetworkTopologyView(nodes: topologyNodes, selectedNodeID: $selectedNodeID)
                    .frame(height: 320)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(DashboardPalette.panel.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(DashboardPalette.border.opacity(0.55), lineWidth: 0.8)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if let selectedNode {
                    nodeSettings(for: selectedNode)
                } else {
                    ContentUnavailableView(
                        "No Device Selected",
                        systemImage: "cursorarrow.click",
                        description: Text("Click a node in the topology map to edit settings.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }

                if let settingsMessage {
                    Text(settingsMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if showConfig {
                    TextEditor(text: .constant(WireGuardManager.shared.exportConfig()))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .padding(10)
                        .background(DashboardPalette.panel.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DashboardPalette.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
        .background(DashboardPalette.surface)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(showConfig ? "Hide Config" : "Show Config") {
                    showConfig.toggle()
                }
            }
        }
        .onAppear {
            WireGuardManager.shared.startDiscovery()
            if selectedNodeID == nil {
                selectedNodeID = WireGuardManager.shared.hostInfo.id
            }
        }
        .onChange(of: topologyNodes.map(\.id)) { _, ids in
            if let current = selectedNodeID, ids.contains(current) {
                return
            }
            selectedNodeID = ids.first
        }
        .onDisappear {
            stopClusterTestLoop()
        }
    }
    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pairedPeers: [WireGuardManager.Peer] {
        WireGuardManager.shared.peers.filter { peer in
            query.isEmpty ||
            peer.name.localizedCaseInsensitiveContains(query) ||
            peer.addressCIDR.localizedCaseInsensitiveContains(query) ||
            "\(peer.endpointHost):\(peer.endpointPort)".localizedCaseInsensitiveContains(query)
        }
    }

    private var discoveredHosts: [DiscoveryManager.DiscoveredHost] {
        let pairedIDs = Set(WireGuardManager.shared.peers.map(\.id))
        return DiscoveryManager.shared.discovered.filter { host in
            !pairedIDs.contains(host.id) &&
            (query.isEmpty ||
             host.name.localizedCaseInsensitiveContains(query) ||
             host.addressCIDR.localizedCaseInsensitiveContains(query) ||
             "\(host.endpointHost):\(host.endpointPort)".localizedCaseInsensitiveContains(query) ||
             (DiscoveryManager.shared.pairStatusByID[host.id] ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    private var topologyNodes: [NetworkTopologyView.TopologyNode] {
        let hostInfo = WireGuardManager.shared.hostInfo
        let local = NetworkTopologyView.TopologyNode(
            id: hostInfo.id,
            name: hostInfo.name,
            kind: .local,
            linkType: localLinkType,
            ipAddress: hostInfo.addressCIDR.split(separator: "/").first.map(String.init) ?? "127.0.0.1"
        )
        let peers = pairedPeers.map {
            NetworkTopologyView.TopologyNode(
                id: $0.id,
                name: $0.name,
                kind: .paired,
                linkType: linkType(forEndpointHost: $0.endpointHost),
                ipAddress: $0.addressCIDR.split(separator: "/").first.map(String.init) ?? ""
            )
        }
        let discovered = discoveredHosts.map {
            NetworkTopologyView.TopologyNode(
                id: $0.id,
                name: $0.name,
                kind: .discovered,
                linkType: linkType(forEndpointHost: $0.endpointHost),
                ipAddress: $0.addressCIDR.split(separator: "/").first.map(String.init) ?? ""
            )
        }
        return [local] + peers + discovered
    }

    private var selectedNode: NetworkTopologyView.TopologyNode? {
        guard let selectedNodeID else { return topologyNodes.first }
        return topologyNodes.first(where: { $0.id == selectedNodeID }) ?? topologyNodes.first
    }

    @ViewBuilder
    private func nodeSettings(for node: NetworkTopologyView.TopologyNode) -> some View {
        switch node.kind {
        case .local:
            localSettings
        case .paired:
            pairedSettings(for: node.id)
        case .discovered:
            discoveredSettings(for: node.id)
        }
    }

    private var localSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This Device")
                .font(.headline)
                .foregroundStyle(OverlayTheme.textPrimary)

            LabeledContent("Host") {
                Text(WireGuardManager.shared.hostInfo.name)
                    .font(.system(.caption, design: .monospaced))
            }

            LabeledContent("Address") {
                Text(WireGuardManager.shared.hostInfo.addressCIDR)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Listen Port") {
                Text("\(WireGuardManager.shared.listenPort)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button(isClusterTestRunning ? "Stop" : "Test Cluster") {
                    if isClusterTestRunning {
                        stopClusterTestLoop()
                    } else {
                        startClusterTestLoop()
                    }
                }
                .controlSize(.small)
            }

            Divider().opacity(0.15)

            Text("Incoming Pair Requests")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OverlayTheme.textPrimary)

            if DiscoveryManager.shared.incomingPairRequests.isEmpty {
                Text("No pending requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(DiscoveryManager.shared.incomingPairRequests.sorted(by: { $0.requestedAt > $1.requestedAt })) { req in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(req.name)
                                    .font(.subheadline.weight(.medium))
                                Text("\(req.endpointHost):\(req.endpointPort)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                Button("Approve") {
                                    DiscoveryManager.shared.approveIncomingPairRequest(id: req.id)
                                    settingsMessage = "Approved \(req.name)."
                                }
                                .controlSize(.small)
                                Button("Reject", role: .destructive) {
                                    DiscoveryManager.shared.rejectIncomingPairRequest(id: req.id)
                                    settingsMessage = "Rejected \(req.name)."
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(DashboardPalette.panel.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func pairedSettings(for id: String) -> some View {
        if let peer = WireGuardManager.shared.peers.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paired Device")
                    .font(.headline)
                    .foregroundStyle(OverlayTheme.textPrimary)

                LabeledContent("Name") { Text(peer.name) }
                LabeledContent("Address") {
                    Text(peer.addressCIDR)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Endpoint") {
                    Text("\(peer.endpointHost):\(peer.endpointPort)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Allowed IPs") {
                    Text(peer.allowedIPs.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Button("Remove Peer", role: .destructive) {
                    WireGuardManager.shared.removePeer(id: peer.id)
                    selectedNodeID = WireGuardManager.shared.hostInfo.id
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(DashboardPalette.panel.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DashboardPalette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Text("Peer no longer available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func discoveredSettings(for id: String) -> some View {
        if let host = DiscoveryManager.shared.discovered.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Discovered Device")
                    .font(.headline)
                    .foregroundStyle(OverlayTheme.textPrimary)

                LabeledContent("Name") { Text(host.name) }
                LabeledContent("Address") {
                    Text(host.addressCIDR)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Endpoint") {
                    Text("\(host.endpointHost):\(host.endpointPort)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    Text(DiscoveryManager.shared.pairStatusByID[host.id] ?? "Waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Request Pair") {
                        pairDiscoveredNode(id: host.id)
                    }
                    .controlSize(.small)

                    Button("Dismiss", role: .destructive) {
                        DiscoveryManager.shared.removeDiscovered(id: host.id)
                        selectedNodeID = WireGuardManager.shared.hostInfo.id
                    }
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(DashboardPalette.panel.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DashboardPalette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Text("Discovered device is no longer available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pairDiscoveredNode(id: String) {
        guard let latest = DiscoveryManager.shared.discovered.first(where: { $0.id == id }) else {
            settingsMessage = "Device is no longer discoverable."
            return
        }
        settingsMessage = "Pairing \(latest.name)…"
        WireGuardManager.shared.pair(discovered: latest) { success, message in
            if success {
                settingsMessage = "Paired with \(latest.name)."
                selectedNodeID = latest.id
            } else {
                settingsMessage = message ?? "Pairing failed."
            }
        }
    }

    private var localLinkType: NetworkTopologyView.LinkType {
        let preferred = HostResources.preferredActiveInterfaceType(preferredTypes: [.thunderbolt, .ethernet, .wifi])
        switch preferred {
        case .wifi:
            return .wifi
        case .ethernet:
            return .ethernet
        case .thunderbolt:
            return .thunderbolt
        case .unknown:
            return .unknown
        }
    }

    private func linkType(forEndpointHost host: String) -> NetworkTopologyView.LinkType {
        let local = localLinkType
        let remote = remoteLinkType(fromEndpointHost: host)

        if remote == .unknown { return local }
        if local == .unknown { return remote }
        if remote != local { return .mixed }
        return remote
    }

    private func remoteLinkType(fromEndpointHost host: String) -> NetworkTopologyView.LinkType {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty {
            return .unknown
        }
        if h.hasPrefix("fe80:") || h.contains("%en0") || h.contains("wifi") || h.contains("wlan") {
            return .wifi
        }
        if h.contains("thunderbolt") || h.contains("bridge") || h.contains("tb") {
            return .thunderbolt
        }
        if h.hasPrefix("169.254.") {
            return .unknown
        }
        return .ethernet
    }

    private func startClusterTestLoop() {
        guard !isClusterTestRunning else { return }
        guard !WireGuardManager.shared.peers.isEmpty else {
            settingsMessage = "No paired devices to test."
            return
        }
        AppNotifications.shared.requestIfNeeded()
        isClusterTestRunning = true
        settingsMessage = "Cluster test started."
        let senderName = WireGuardManager.shared.hostInfo.name
        clusterTestTask = Task {
            while !Task.isCancelled {
                let peers = WireGuardManager.shared.peers
                if peers.isEmpty {
                    await MainActor.run {
                        settingsMessage = "No paired devices available."
                        isClusterTestRunning = false
                    }
                    return
                }
                for peer in peers {
                    if Task.isCancelled { return }
                    do {
                        let result = try await ClusterManager.shared.runBandwidthTest(to: peer, senderName: senderName)
                        await MainActor.run {
                            settingsMessage = "100 MB -> \(result.receiverName): \(Int(result.mbps)) MB/s"
                            AppNotifications.shared.notify(
                                id: "cluster-test-sent-\(result.receiverID)",
                                title: "Cluster Test Sent",
                                body: "100 MB to \(result.receiverName): \(Int(result.mbps)) MB/s",
                                minimumInterval: 1
                            )
                        }
                    } catch {
                        await MainActor.run {
                            settingsMessage = "Test failed for \(peer.name): \(error.localizedDescription)"
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func stopClusterTestLoop() {
        clusterTestTask?.cancel()
        clusterTestTask = nil
        if isClusterTestRunning {
            settingsMessage = "Cluster test stopped."
        }
        isClusterTestRunning = false
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
        case .paused: return .yellow
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
    @State private var selectedDistro: VirtualMachine.LinuxDistro = .talos
    @State private var errorMessage: String? = nil
    @State private var isDeploying: Bool = false
    
    // Added network mode and bridge interface selection states
    @State private var selectedNetworkMode: VMNetworkMode = .bridge
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
                selectedNetworkMode = .bridge
            }
            if !interfaces.contains(where: { $0.bsdName == selectedBridgeName }) {
                selectedBridgeName = interfaces.first?.bsdName ?? ""
            }
            if !interfaces.contains(where: { $0.bsdName == secondaryBridgeName }) {
                secondaryBridgeName = interfaces.first?.bsdName ?? ""
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
                        Text(VirtualMachine.LinuxDistro.talos.rawValue)
                            .font(.system(.body, design: .monospaced))
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
                                Text("Select interface").tag("")
                                if interfaces.isEmpty {
                                    Text("No interface available").tag("")
                                }
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
                                    Text("Select interface").tag("")
                                    if interfaces.isEmpty {
                                        Text("No interface available").tag("")
                                    }
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
                    ramMB: memoryGB * 1024,
                    sysDiskGB: systemDiskGB,
                    dataDiskGB: useDedicatedLonghornDisk ? dataDiskGB : 0,
                    isMaster: isMaster,
                    distro: selectedDistro,
                    networkMode: selectedNetworkMode,
                    bridgeInterfaceName: selectedNetworkMode == .bridge ? selectedBridgeName : nil,
                    secondaryNetworkEnabled: enableSecondaryNetwork,
                    secondaryNetworkMode: secondaryNetworkMode,
                    secondaryBridgeInterfaceName: (enableSecondaryNetwork && secondaryNetworkMode == .bridge) ? secondaryBridgeName : nil
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
        if ratio >= 0.9 { return Color.white.opacity(0.92) }
        if ratio >= 0.75 { return Color.white.opacity(0.78) }
        return Color.white.opacity(0.62)
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
            .background(isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.white.opacity(0.88) : Color.clear, lineWidth: 2))
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
                .background(isSelected ? Color.white.opacity(0.84) : Color.white.opacity(0.05))
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
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : .secondary)
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(Color.white.opacity(0.9))
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
            .background(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.03))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.white.opacity(0.34) : Color.white.opacity(0.05), lineWidth: 1)
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
                    .foregroundStyle(value > safeMax ? Color.white.opacity(0.56) : Color.white.opacity(0.9))
            }
            
            Slider(value: $value, in: range, step: step)
                .tint(value > safeMax ? Color.white.opacity(0.42) : Color.white.opacity(0.84))
                .controlSize(.small)
        }
    }
}
#endif
