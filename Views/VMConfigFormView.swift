import SwiftUI
import AppKit

struct VMConfigForm: View {
    @Environment(\.dismiss) private var dismiss

    enum PresentationStyle {
        case sheet
        case drawer
    }

    private func pickHostFolder(for mountID: UUID) {
        pendingMountSelection = mountID
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Folder"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let index = containerMounts.firstIndex(where: { $0.id == mountID }) {
                containerMounts[index].hostPath = url.path
                // If the guest path is empty or still at the default placeholder, propose a sensible mount point.
                let currentGuest = containerMounts[index].containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentGuest.isEmpty || currentGuest == "/mnt/shared" {
                    let name = url.lastPathComponent.isEmpty ? "shared" : url.lastPathComponent
                    containerMounts[index].containerPath = "/mnt/shared/\(name)"
                }
            }
        }
    }

    @Binding var isPresented: Bool
    let vmToEdit: VirtualMachine?
    var presentationStyle: PresentationStyle = .sheet

    @State private var vmName: String = ""
    @State private var cpuCount: Int = 1
    @State private var memoryMB: Int = 512
    @State private var systemDiskGB: Int = 40
    @State private var dataDiskGB: Int = 100
    @State private var useDedicatedLonghornDisk: Bool = true
    @State private var isMaster: Bool = false
    @State private var selectedDistro: VirtualMachine.LinuxDistro = .debian13
    @State private var errorMessage: String? = nil
    @State private var isDeploying: Bool = false

    @State private var selectedNetworkMode: VMNetworkMode = .nat
    @State private var selectedBridgeName: String = ""
    @State private var enableSecondaryNetwork: Bool = false
    @State private var secondaryNetworkMode: VMNetworkMode = .nat
    @State private var secondaryBridgeName: String = ""
    @State private var containerImageReference: String = ""
    @State private var availableContainerImages: [ContainerImageInfo] = []
    @State private var selectedServerImagePreset: ServerImagePreset = .debian
    @State private var isPulling: Bool = false
    @State private var pullProgress: Double = 0
    @State private var pullDetail: String = ""
    @State private var containerMounts: [VirtualMachine.ContainerMount] = []
    @State private var containerPorts: [VirtualMachine.ContainerPort] = []
    @State private var pendingMountSelection: UUID?
    @State private var zeroTouchEnabled: Bool = false
    @State private var preseedHostIP: String = "192.168.64.1"

    private let maxCores = max(1, HostResources.cpuCount - 2)
    private let maxRAM_MB = max(128, (HostResources.totalMemoryGB * 1024) - 1024)
    private let freeDisk = HostResources.freeDiskSpaceGB
    private let interfaces = HostResources.getNetworkInterfaces()
    private var isEditing: Bool { vmToEdit != nil }
    private var isContainerMode: Bool {
        AppSettingsStore.shared.workloadRuntime == .appleContainer
    }
    private var primaryActionTitle: String {
        isEditing ? "Save" : (isContainerMode ? "Create Container" : "Deploy")
    }
    private var recommendedCPU: Int {
        max(1, min(maxCores, HostResources.cpuCount / 2))
    }
    private var recommendedRAMMB: Int {
        let quarter = HostResources.systemAvailableMemoryMB / 4
        return min(maxRAM_MB, max(512, quarter))
    }
    private var recommendedSystemDiskGB: Int {
        max(10, min(40, freeDisk / 4))
    }

    private enum ServerImagePreset: String, CaseIterable, Identifiable {
        case debian = "Debian Server"
        case ubuntu = "Ubuntu Server"
        case almalinux = "AlmaLinux"
        case rockylinux = "Rocky Linux"
        case fedora = "Fedora Server"
        case opensuse = "openSUSE Leap"

        var id: String { rawValue }

        var imageReference: String {
            switch self {
            case .debian:
                return "debian:latest"
            case .ubuntu:
                return "ubuntu:latest"
            case .almalinux:
                return "almalinux:latest"
            case .rockylinux:
                return "rockylinux:latest"
            case .fedora:
                return "fedora:latest"
            case .opensuse:
                return "opensuse/leap:latest"
            }
        }
    }

    var body: some View {
        Group {
            if presentationStyle == .sheet {
                NavigationStack {
                    formContent
                        .navigationTitle(isEditing ? (isContainerMode ? "Edit Container" : "Edit Node") : (isContainerMode ? "Create Container" : "Deploy Node"))
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
                        Text(isEditing ? (isContainerMode ? "Edit Container" : "Edit Node") : (isContainerMode ? "Create Container" : "Deploy Node"))
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
                    .background(OverlayTheme.panelStrong)

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
                    .background(OverlayTheme.panelStrong)
                }
                .background(
                    LinearGradient(
                        colors: [DashboardPalette.panelAlt, OverlayTheme.panelStrong],
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
            clampInputs()
            startPreseedIfNeeded()
            if let vm = vmToEdit {
                vmName = vm.name
                cpuCount = vm.cpuCount
                memoryMB = vm.memorySizeMB
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
                if !vm.containerImageReference.isEmpty {
                    containerImageReference = vm.containerImageReference
                    if let preset = ServerImagePreset.allCases.first(where: { $0.imageReference == vm.containerImageReference }) {
                        selectedServerImagePreset = preset
                    }
                }
                containerMounts = vm.containerMounts
                containerPorts = vm.containerPorts
            } else if vmName.isEmpty {
                vmName = isContainerMode ? "container-\(Int.random(in: 100...999))" : "node-\(Int.random(in: 100...999))"
                if !interfaces.isEmpty {
                    selectedNetworkMode = .bridge
                }
                
                // Smart defaults based on available power
                let availCPU = VMManager.shared.availableCPU
                let availRAM = VMManager.shared.availableMemoryMB
                
                if isContainerMode {
                    cpuCount = max(1, min(2, availCPU))
                    memoryMB = max(256, min(2048, availRAM / 4))
                } else {
                    cpuCount = max(1, min(4, availCPU / 2))
                    memoryMB = max(1024, min(8192, availRAM / 2))
                }
            }
            if selectedBridgeName.isEmpty, let first = interfaces.first {
                selectedBridgeName = first.bsdName
            }
            if secondaryBridgeName.isEmpty, let first = interfaces.first {
                secondaryBridgeName = first.bsdName
            }
            if isContainerMode {
                Task { @MainActor in
                    availableContainerImages = (try? await VMManager.shared.listContainerImages()) ?? []
                    if containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let first = availableContainerImages.first {
                        containerImageReference = first.reference
                    } else if containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        containerImageReference = selectedServerImagePreset.imageReference
                    }
                }
            }
        }
        .alert(isEditing ? "Save failed" : (isContainerMode ? "Container creation failed" : "Deploy failed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
                        TextField(isContainerMode ? "Container Name" : "Node Name", text: $vmName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(isEditing)
                        if !isContainerMode {
                            Picker("Role", selection: $isMaster) {
                                Text("Worker").tag(false)
                                Text("Master").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                if !isContainerMode {
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
                            if selectedDistro == .debian13 {
                                Toggle("Zero-touch install (preseed)", isOn: $zeroTouchEnabled)
                                    .onChange(of: zeroTouchEnabled) { _, newValue in
                                        if newValue {
                                            preseedHostIP = HostResources.defaultNATHostIP
                                        }
                                    }
                            }
                        }
                    }
                }

                if isContainerMode {
                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Container Image")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            HStack(spacing: 12) {
                                TextField("Image Reference (e.g. ubuntu:latest)", text: $containerImageReference)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                
                                Button {
                                    pullImage()
                                } label: {
                                    if isPulling {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Pull")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isPulling || containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            
                            if isPulling {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView(value: pullProgress)
                                        .progressViewStyle(.linear)
                                    Text(pullDetail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if !availableContainerImages.isEmpty {
                                Picker("Local Images", selection: $containerImageReference) {
                                    Text("--- Select image ---").tag("")
                                    if !containerImageReference.isEmpty &&
                                        !availableContainerImages.contains(where: { $0.reference == containerImageReference }) {
                                        Text("Current: \(containerImageReference)").tag(containerImageReference)
                                    }
                                    ForEach(availableContainerImages) { image in
                                        Text(image.reference).tag(image.reference)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Resources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        if !isEditing {
                            Button {
                                cpuCount = recommendedCPU
                                memoryMB = recommendedRAMMB
                                systemDiskGB = recommendedSystemDiskGB
                                clampInputs()
                            } label: {
                                Label("Apply recommended (balanced)", systemImage: "wand.and.stars")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("CPU")
                                Spacer()
                                Text("\(cpuCount)")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(cpuCount > maxCores ? Color.red : DashboardPalette.textSecondary)
                            }
                            HStack {
                                Text("Recommended: \(recommendedCPU)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Host: \(HostResources.cpuCount) cores")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(cpuCount) },
                                    set: { cpuCount = Int($0.rounded()) }
                                ),
                                in: 1...Double(HostResources.cpuCount),
                                step: 1
                            )
                        }
                        
                        let totalCPU = HostResources.cpuCount
                        let reservedCPU = VMManager.shared.totalAllocatedCPU - (isEditing ? (vmToEdit?.cpuCount ?? 0) : 0)
                        let availCPU = VMManager.shared.availableCPU + (isEditing ? (vmToEdit?.cpuCount ?? 0) : 0)

                        VStack(alignment: .leading, spacing: 4) {
                            CapacityBar(title: "Host CPU Allocation", used: cpuCount, reserved: reservedCPU, total: totalCPU)
                            Text("Available: \(availCPU) Cores")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(availCPU < cpuCount ? .red : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("RAM")
                                Spacer()
                                Text("\(memoryMB) MB")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(memoryMB > maxRAM_MB ? Color.red : DashboardPalette.textSecondary)
                            }
                            HStack {
                                Text("Recommended: \(recommendedRAMMB) MB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Host free: \(HostResources.systemAvailableMemoryMB) MB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(memoryMB) },
                                    set: { memoryMB = Int($0.rounded() / 50.0) * 50 }
                                ),
                                in: 50...Double(HostResources.totalMemoryGB * 1024),
                                step: 50
                            )
                        }

                        let totalRAM = HostResources.totalMemoryGB * 1024
                        let reservedRAM = VMManager.shared.totalAllocatedMemoryMB - (isEditing ? (vmToEdit?.memorySizeMB ?? 0) : 0)
                        let availRAM = VMManager.shared.availableMemoryMB + (isEditing ? (vmToEdit?.memorySizeMB ?? 0) : 0)
                        let systemAvail = HostResources.systemAvailableMemoryMB

                        VStack(alignment: .leading, spacing: 4) {
                            CapacityBar(title: "Host RAM Allocation", used: memoryMB, reserved: reservedRAM, total: totalRAM)
                            HStack {
                                Text("Available: \(availRAM) MB")
                                Spacer()
                                Text("System Free: \(systemAvail) MB")
                            }
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(availRAM < memoryMB ? .red : .secondary)
                        }
                        if !isContainerMode {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("System Disk")
                                    Spacer()
                                    Text("\(systemDiskGB) GB")
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(DashboardPalette.textSecondary)
                                }
                                HStack {
                                    Text("Recommended: \(recommendedSystemDiskGB) GB")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Host free: \(freeDisk) GB")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(systemDiskGB) },
                                        set: { systemDiskGB = Int($0.rounded() / 5.0) * 5 }
                                    ),
                                    in: 5...200,
                                    step: 5
                                )
                            }
                            CapacityBar(title: "Estimated Host Disk", used: systemDiskGB + (useDedicatedLonghornDisk ? dataDiskGB : 0), total: max(1, freeDisk))
                        }
                    }
                }

                if !isContainerMode {
                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Storage")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            Toggle("Dedicated Longhorn Disk", isOn: $useDedicatedLonghornDisk)
                            if useDedicatedLonghornDisk {
                                let maxData = max(5, freeDisk - systemDiskGB - 10)
                                let clampedMax = max(5.0, Double(maxData))
                                let hasRoomForSlider = clampedMax > 5.0
                                let effectiveData = min(Double(dataDiskGB), clampedMax)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Longhorn Disk")
                                        Spacer()
                                        Text("\(Int(effectiveData)) GB")
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle((systemDiskGB + Int(effectiveData)) > freeDisk ? Color.red : DashboardPalette.textSecondary)
                                    }
                                    if hasRoomForSlider {
                                        Slider(
                                            value: Binding(
                                                get: { effectiveData },
                                                set: { dataDiskGB = min(Int($0.rounded() / 5.0) * 5, Int(clampedMax)) }
                                            ),
                                            in: 5...clampedMax,
                                            step: 5
                                        )
                                    } else {
                                        Text("Not enough host disk headroom for a data disk.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                CapacityBar(title: "Storage Pressure", used: systemDiskGB + Int(effectiveData), total: max(1, freeDisk))
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
                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Volumes & Shared Folders")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            
                            if containerMounts.isEmpty {
                                Text("No shared folders configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            ForEach($containerMounts) { $mount in
                                VStack(spacing: 8) {
                                    HStack {
                                        TextField("Host Path", text: $mount.hostPath)
                                            .textFieldStyle(.roundedBorder)
                                        Button {
                                            pickHostFolder(for: mount.id)
                                        } label: {
                                            Image(systemName: "folder.badge.plus")
                                        }
                                        .buttonStyle(.borderless)
                                        Image(systemName: "arrow.right")
                                            .foregroundStyle(.secondary)
                                        TextField("Guest Path", text: $mount.containerPath)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    HStack {
                                        Toggle("Read Only", isOn: $mount.isReadOnly)
                                            .font(.caption)
                                        Spacer()
                                        Button(role: .destructive) {
                                            containerMounts.removeAll(where: { $0.id == mount.id })
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red.opacity(0.8))
                                    }
                                    Text("Inside VM, this will appear at \(mount.containerPath)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.03))
                                .cornerRadius(8)
                            }
                            
                            Button {
                                containerMounts.append(VirtualMachine.ContainerMount(hostPath: "", containerPath: "/mnt/shared"))
                            } label: {
                                Label("Add Shared Folder", systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Network Port Forwarding")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DashboardPalette.textSecondary)
                            
                            if containerPorts.isEmpty {
                                Text("No ports exposed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            ForEach($containerPorts) { $port in
                                VStack(spacing: 8) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Host Port").font(.caption2).foregroundStyle(.secondary)
                                            TextField("Host", value: $port.hostPort, format: .number)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                        Image(systemName: "arrow.right")
                                            .padding(.top, 16)
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Guest Port").font(.caption2).foregroundStyle(.secondary)
                                            TextField("Guest", value: $port.containerPort, format: .number)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                    HStack {
                                        Picker("Protocol", selection: $port.protocolName) {
                                            Text("TCP").tag("tcp")
                                            Text("UDP").tag("udp")
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 120)
                                        
                                        Spacer()
                                        
                                        Button(role: .destructive) {
                                            containerPorts.removeAll(where: { $0.id == port.id })
                                        } label: {
                                            Label("Kill", systemImage: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red.opacity(0.8))
                                    }
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.03))
                                .cornerRadius(8)
                            }
                            
                            Button {
                                containerPorts.append(VirtualMachine.ContainerPort(hostPort: 8080, containerPort: 80))
                            } label: {
                                Label("Add Port Mapping", systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
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

    private func pullImage() {
        let reference = containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return }
        
        isPulling = true
        pullProgress = 0
        pullDetail = "Initializing pull..."
        
        Task {
            do {
                try await VMManager.shared.pullContainerImage(reference: reference) { progress, detail in
                    Task { @MainActor in
                        self.pullProgress = progress
                        self.pullDetail = detail
                    }
                }
                isPulling = false
                availableContainerImages = (try? await VMManager.shared.listContainerImages()) ?? []
            } catch {
                errorMessage = "Pull failed: \(error.localizedDescription)"
                isPulling = false
            }
        }
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
                    vm.memorySizeMB = memoryMB
                    if vm.state == .stopped && !isContainerMode {
                        vm.systemDiskSizeGB = systemDiskGB
                        vm.dataDiskSizeGB = useDedicatedLonghornDisk ? dataDiskGB : 0
                    }
                    vm.isMaster = isMaster
                    vm.selectedDistro = selectedDistro
                    if isContainerMode {
                        let selected = containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
                        vm.containerImageReference = selected.isEmpty ? selectedServerImagePreset.imageReference : selected
                        vm.containerMounts = containerMounts
                        vm.containerPorts = containerPorts
                    } else {
                        vm.networkMode = selectedNetworkMode
                        vm.bridgeInterfaceName = selectedNetworkMode == .bridge ? selectedBridgeName : nil
                        vm.secondaryNetworkEnabled = enableSecondaryNetwork
                        vm.secondaryNetworkMode = secondaryNetworkMode
                        vm.secondaryBridgeInterfaceName = (enableSecondaryNetwork && secondaryNetworkMode == .bridge) ? secondaryBridgeName : nil
                    }
                    vm.persist()
                    isDeploying = false
                    closeForm()
                    return
                }

                _ = try await VMManager.shared.createLinuxVM(
                    name: vmName,
                    cpus: cpuCount,
                    ramMB: memoryMB,
                    sysDiskGB: isContainerMode ? 20 : systemDiskGB,
                    dataDiskGB: isContainerMode ? 0 : (useDedicatedLonghornDisk ? dataDiskGB : 0),
                    isMaster: isMaster,
                    distro: selectedDistro,
                    containerImageReference: isContainerMode ? {
                        let selected = containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
                        return selected.isEmpty ? selectedServerImagePreset.imageReference : selected
                    }() : nil,
                    containerMounts: containerMounts,
                    containerPorts: containerPorts,
                    networkMode: isContainerMode ? .nat : selectedNetworkMode,
                    bridgeInterfaceName: isContainerMode ? nil : selectedBridgeName,
                    secondaryNetworkEnabled: isContainerMode ? false : enableSecondaryNetwork,
                    secondaryNetworkMode: isContainerMode ? .nat : secondaryNetworkMode,
                    secondaryBridgeInterfaceName: isContainerMode ? nil : secondaryBridgeName,
                    zeroTouch: selectedDistro == .debian13 ? zeroTouchEnabled : false
                )

                isDeploying = false
                closeForm()
            } catch {
                errorMessage = error.localizedDescription
                isDeploying = false
            }
        }
    }
    private func clampInputs() {
        cpuCount = min(max(1, cpuCount), HostResources.cpuCount)
        let maxRam = HostResources.totalMemoryGB * 1024
        memoryMB = min(max(50, memoryMB), maxRam)
        systemDiskGB = min(max(5, systemDiskGB), 200)
        let maxData = max(5, HostResources.freeDiskSpaceGB - systemDiskGB - 10)
        if dataDiskGB > maxData { dataDiskGB = maxData }
        if dataDiskGB < 5 { dataDiskGB = 5 }
        preseedHostIP = preseedHostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if preseedHostIP.isEmpty { preseedHostIP = "192.168.64.1" }
    }

    private func startPreseedIfNeeded() {
        guard selectedDistro == .debian13, zeroTouchEnabled else { return }
        preseedHostIP = HostResources.defaultNATHostIP
        VMManager.shared.ensurePreseedServerRunning()
    }
}

struct CapacityBar: View {
    let title: String
    let used: Int // This selection
    var reserved: Int = 0 // Already used by other VMs
    let total: Int

    private var ratioUsed: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }
    
    private var ratioReserved: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(reserved) / Double(total))
    }

    private var barColor: Color {
        let totalRatio = (Double(used + reserved) / Double(total))
        if totalRatio >= 0.95 { return .red.opacity(0.8) }
        if totalRatio >= 0.8 { return .orange.opacity(0.8) }
        return Color.white.opacity(0.62)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(used + reserved)/\(total)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(barColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    
                    // Reserved segment
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: max(0, geo.size.width * ratioReserved))
                    
                    // Current selection segment
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(6, geo.size.width * ratioUsed))
                        .offset(x: geo.size.width * ratioReserved)
                }
            }
            .frame(height: 8)
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
            .background(isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.05))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.white.opacity(0.88) : Color.clear, lineWidth: 2))
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
                .background(isSelected ? Color.white.opacity(0.84) : Color.white.opacity(0.05))
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
                    .foregroundStyle(value > safeMax ? Color.white.opacity(0.56) : Color.white.opacity(0.9))
            }

            Slider(value: $value, in: range, step: step)
                .tint(value > safeMax ? Color.white.opacity(0.42) : Color.white.opacity(0.84))
                .controlSize(.small)
        }
    }
}
