import SwiftUI

struct VMConfigForm: View {
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

    @State private var selectedNetworkMode: VMNetworkMode = .nat
    @State private var selectedBridgeName: String = ""
    @State private var enableSecondaryNetwork: Bool = false
    @State private var secondaryNetworkMode: VMNetworkMode = .nat
    @State private var secondaryBridgeName: String = ""
    @State private var containerImageReference: String = "debian:testing"
    @State private var availableContainerImages: [ContainerImageInfo] = []
    @State private var selectedServerImagePreset: ServerImagePreset = .debian

    private let maxCores = max(1, HostResources.cpuCount - 2)
    private let maxRAM = max(2, HostResources.totalMemoryGB - 2)
    private let freeDisk = HostResources.freeDiskSpaceGB
    private let interfaces = HostResources.getNetworkInterfaces()
    private var isEditing: Bool { vmToEdit != nil }
    private var isContainerMode: Bool {
        AppSettingsStore.shared.workloadRuntime == .appleContainer
    }
    private var primaryActionTitle: String {
        isEditing ? "Save" : (isContainerMode ? "Create Container" : "Deploy")
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
                if !vm.containerImageReference.isEmpty {
                    containerImageReference = vm.containerImageReference
                    if let preset = ServerImagePreset.allCases.first(where: { $0.imageReference == vm.containerImageReference }) {
                        selectedServerImagePreset = preset
                    }
                }
            } else if vmName.isEmpty {
                vmName = isContainerMode ? "container-\(Int.random(in: 100...999))" : "node-\(Int.random(in: 100...999))"
                if !interfaces.isEmpty {
                    selectedNetworkMode = .bridge
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
                        Picker("Role", selection: $isMaster) {
                            Text("Worker").tag(false)
                            Text("Master").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                DashboardPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(isContainerMode ? "Server Image Family" : "Distribution")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DashboardPalette.textSecondary)
                        if isContainerMode {
                            Picker("Server Images", selection: $selectedServerImagePreset) {
                                ForEach(ServerImagePreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .onChange(of: selectedServerImagePreset) { _, newPreset in
                                if availableContainerImages.first(where: { $0.reference == containerImageReference }) == nil {
                                    containerImageReference = newPreset.imageReference
                                }
                            }
                        } else {
                            Picker("Linux", selection: $selectedDistro) {
                                ForEach(VirtualMachine.LinuxDistro.allCases) { distro in
                                    Text(distro.rawValue).tag(distro)
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
                            TextField("Image Reference (e.g. ubuntu:latest)", text: $containerImageReference)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            if !availableContainerImages.isEmpty {
                                Picker("Local Images", selection: $containerImageReference) {
                                    ForEach(availableContainerImages) { image in
                                        Text(image.reference).tag(image.reference)
                                    }
                                }
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
                        if !isContainerMode {
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
                    if vm.state == .stopped && !isContainerMode {
                        vm.systemDiskSizeGB = systemDiskGB
                        vm.dataDiskSizeGB = useDedicatedLonghornDisk ? dataDiskGB : 0
                    }
                    vm.isMaster = isMaster
                    vm.selectedDistro = selectedDistro
                    if isContainerMode {
                        let selected = containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
                        vm.containerImageReference = selected.isEmpty ? selectedServerImagePreset.imageReference : selected
                    } else {
                        vm.networkMode = selectedNetworkMode
                        vm.bridgeInterfaceName = selectedNetworkMode == .bridge ? selectedBridgeName : nil
                        vm.secondaryNetworkEnabled = enableSecondaryNetwork
                        vm.secondaryNetworkMode = secondaryNetworkMode
                        vm.secondaryBridgeInterfaceName = (enableSecondaryNetwork && secondaryNetworkMode == .bridge) ? secondaryBridgeName : nil
                    }
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
                    sysDiskGB: isContainerMode ? 20 : systemDiskGB,
                    dataDiskGB: isContainerMode ? 0 : (useDedicatedLonghornDisk ? dataDiskGB : 0),
                    isMaster: isMaster,
                    distro: selectedDistro,
                    containerImageReference: isContainerMode ? {
                        let selected = containerImageReference.trimmingCharacters(in: .whitespacesAndNewlines)
                        return selected.isEmpty ? selectedServerImagePreset.imageReference : selected
                    }() : nil,
                    networkMode: isContainerMode ? .nat : selectedNetworkMode,
                    bridgeInterfaceName: isContainerMode ? nil : selectedBridgeName,
                    secondaryNetworkEnabled: isContainerMode ? false : enableSecondaryNetwork,
                    secondaryNetworkMode: isContainerMode ? .nat : secondaryNetworkMode,
                    secondaryBridgeInterfaceName: isContainerMode ? nil : secondaryBridgeName
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

struct CapacityBar: View {
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
