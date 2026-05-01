import SwiftUI

struct TalosSetupView: View {
    let search: String

    // Auto-setup service
    @State private var autoService = TalosAutoSetupService.shared

    // Manual setup (collapsed by default)
    @State private var manualService = TalosSetupService.shared
    @State private var showManualSetup = false
    @State private var clusterName: String = "mlv-talos"
    @State private var endpoint: String = ""
    @State private var controlPlaneInput: String = ""
    @State private var workerInput: String = ""

    // Detected VMs
    @State private var detectedVMs: [VirtualMachine] = []

    // ClusterCore deploy state (now integrated into progress bar)
    @State private var isDeployingClusterCore = false
    @State private var clusterCoreDeployError: String?
    @State private var clusterCoreDeploySuccess = false

    private var filteredLogs: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLogs = autoService.logs + manualService.logs
        guard !query.isEmpty else { return allLogs }
        return allLogs.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var runningTalosVMs: [VirtualMachine] {
        VMManager.shared.virtualMachines.filter {
            $0.selectedDistro == .talos && $0.state == .running
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with status
                headerSection

                // Stages progress bar
                stagesProgressSection

                // Auto-detected VMs
                detectedVMsSection

                // Actions
                actionsSection


                // Expandable manual setup
                if showManualSetup {
                    manualSetupSection
                }

                // Logs
                logsSection
            }
            .padding(20)
        }
        .background(DashboardPalette.surface)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Install talosctl") {
                    TerminalLauncher.openAndRun("brew install siderolabs/tap/talosctl")
                }
            }
        }
        .onAppear {
            updateDetectedVMs()
            restoreProgressStage()
        }
        .onChange(of: runningTalosVMs.count) {
            updateDetectedVMs()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gear.badge.checkmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Talos Setup")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(OverlayTheme.textPrimary)

                    Text("Automatic configuration for Talos VMs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OverlayTheme.textSecondary)
                }

                Spacer()

                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(autoService.isRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(autoService.isRunning ? "Working" : "Ready")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(autoService.isRunning ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }

    private var stagesProgressSection: some View {
        let stage = autoService.currentStage
        let showPrompt = autoService.pendingClusterCoreVM != nil

        return DashboardPanel {
            VStack(alignment: .leading, spacing: 14) {
                // Current stage label
                HStack(spacing: 8) {
                    Image(systemName: stage.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(stageColor(stage))
                        .symbolEffect(.pulse, options: .repeating, isActive: autoService.isRunning)

                    if !autoService.currentVMName.isEmpty {
                        Text(autoService.currentVMName)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(OverlayTheme.textSecondary)
                    }

                    Text(stage.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stageColor(stage))

                    Spacer()

                    if autoService.isRunning {
                        Text("\(Int(stage.progress * 100))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(OverlayTheme.textSecondary)
                    }
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 8)

                        // Filled progress
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: stage == .failed
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : [.blue.opacity(0.8), .cyan.opacity(0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: autoService.isRunning || stage == .completed || showPrompt ? geo.size.width * stage.progress : 0, height: 8)
                            .animation(.easeInOut(duration: 0.5), value: stage)
                    }
                }
                .frame(height: 8)

                // Stage dots with section divider
                VStack(spacing: 8) {
                    // Talos stages row
                    HStack(spacing: 0) {
                        ForEach(TalosSetupStage.talosStages) { s in
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(stageDotFill(s, current: stage))
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(stageDotStroke(s, current: stage), lineWidth: 1.5)
                                    )

                                Text(s.label)
                                    .font(.system(size: 9, weight: stage == s ? .bold : .regular))
                                    .foregroundStyle(stage == s ? OverlayTheme.textPrimary : OverlayTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    // ClusterCore stages row (always visible, dimmed if not applicable)
                    HStack(spacing: 0) {
                        ForEach(TalosSetupStage.clusterCoreStages) { s in
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(stageDotFill(s, current: stage))
                                    .frame(width: 10, height: 10)
                                    .overlay(
                                        Circle()
                                            .stroke(stageDotStroke(s, current: stage), lineWidth: 1.5)
                                    )

                                Text(s.label)
                                    .font(.system(size: 9, weight: stage == s ? .bold : .regular))
                                    .foregroundStyle(stage == s ? OverlayTheme.textPrimary : OverlayTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .opacity(showPrompt || stage == .waitingForK8sAPI || stage == .deployingClusterCore || stage == .completed ? 1.0 : 0.35)
                }

                // ClusterCore prompt (appears when Talos setup completes, or retry after failure)
                if showPrompt {
                    let isFailed = stage == .failed
                    let accentColor: Color = isFailed ? .orange : .purple

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "server.rack")
                                .font(.system(size: 20))
                                .foregroundStyle(accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(isFailed ? "ClusterCore Failed — Retry?" : "Deploy ClusterCore?")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(OverlayTheme.textPrimary)
                                Text("k8sdevops dashboard, production & development namespaces on \(autoService.pendingClusterCoreVM?.name ?? "control plane")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OverlayTheme.textSecondary)
                            }
                        }

                        if isFailed, let lastError = autoService.logs.last(where: { $0.contains("failed") || $0.contains("error") || $0.contains("Error") }) {
                            Text(lastError)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.85))
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        HStack(spacing: 12) {
                            Button {
                                autoService.deployClusterCoreAfterSetup()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: isFailed ? "arrow.clockwise" : "arrow.triangle.2.circlepath")
                                    Text(isFailed ? "Retry ClusterCore" : "Deploy ClusterCore")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)

                            Button {
                                autoService.skipClusterCore()
                            } label: {
                                Text("Skip")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accentColor.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accentColor.opacity(0.25), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func stageColor(_ stage: TalosSetupStage) -> Color {
        switch stage {
        case .completed: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .blue
        }
    }

    private func stageDotFill(_ stage: TalosSetupStage, current: TalosSetupStage) -> Color {
        if current == .completed { return .green }
        if current == .failed && stage.rawValue <= current.rawValue { return .red.opacity(0.6) }
        if stage.rawValue < current.rawValue { return .blue }
        if stage == current { return .blue }
        // ClusterCore stages glow purple when pending
        if TalosSetupStage.clusterCoreStages.contains(stage) && autoService.pendingClusterCoreVM != nil {
            return .purple.opacity(0.4)
        }
        return .clear
    }

    private func stageDotStroke(_ stage: TalosSetupStage, current: TalosSetupStage) -> Color {
        if current == .completed { return .green }
        if stage.rawValue < current.rawValue { return .blue.opacity(0.4) }
        if stage == current { return .blue }
        // ClusterCore stages glow purple when pending
        if TalosSetupStage.clusterCoreStages.contains(stage) && autoService.pendingClusterCoreVM != nil {
            return .purple.opacity(0.6)
        }
        return .white.opacity(0.15)
    }

    private var detectedVMsSection: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Detected VMs")
                        .font(.headline)
                        .foregroundStyle(OverlayTheme.textPrimary)

                    Spacer()

                    Text("\(detectedVMs.count) running")
                        .font(.system(size: 12))
                        .foregroundStyle(OverlayTheme.textSecondary)
                }

                if detectedVMs.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("No running Talos VMs detected")
                            .font(.system(size: 13))
                            .foregroundStyle(OverlayTheme.textSecondary)
                    }
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(detectedVMs) { vm in
                            vmRow(vm)
                        }
                    }
                }
            }
        }
    }

    private func vmRow(_ vm: VirtualMachine) -> some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: vm.isConnected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(vm.isConnected ? .green : .orange)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OverlayTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(vm.ipAddress)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OverlayTheme.textSecondary)

                    if vm.isMaster {
                        Text("Control Plane")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .clipShape(Capsule())
                    }

                    if vm.talosSetupCompleted {
                        Label("Talos Ready", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if vm.clusterCoreDeployed {
                        Label("ClusterCore", systemImage: "server.rack")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(Capsule())

                        // Dashboard URL shortcut
                        Button {
                            if let url = URL(string: "http://\(vm.ipAddress):30005") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open Dashboard", systemImage: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.cyan)
                        }
                        .buttonStyle(.borderless)
                        .help("http://\(vm.ipAddress):30005")

                        // Copy password button
                        if !vm.clusterCoreDashboardPassword.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vm.clusterCoreDashboardPassword, forType: .string)
                            } label: {
                                Label("Copy Password", systemImage: "key.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy dashboard password: \(vm.clusterCoreDashboardPassword)")
                        }
                    }
                }
            }

            Spacer()

            if vm.isConnected {
                // Manual bootstrap button for control plane
                if vm.isMaster {
                    Button {
                        runManualBootstrap(vm)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Manual bootstrap")
                }

                Button {
                    TalosAutoSetupService.shared.retrySetup(for: vm)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Retry full setup")
            }
        }
        .padding(12)
        .background(DashboardPalette.panel.opacity(0.3))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            // Auto setup all button
            Button {
                for vm in detectedVMs where vm.isConnected {
                    TalosAutoSetupService.shared.retrySetup(for: vm)
                }
            } label: {
                Label("Auto Setup All", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(detectedVMs.isEmpty || autoService.isRunning)

            // Manual toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showManualSetup.toggle()
                }
            } label: {
                Label(showManualSetup ? "Hide Manual" : "Manual Setup", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)

            Spacer()

            // Clear logs
            Button {
                autoService.clearLogs()
                manualService.clearLogs()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear logs")
        }
    }

    // ClusterCore section removed - now integrated into progress bar as a post-setup prompt

    private var manualSetupSection: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Manual Configuration")
                        .font(.headline)
                        .foregroundStyle(OverlayTheme.textPrimary)

                    Spacer()

                    Button {
                        autoFillFromDetectedVMs()
                    } label: {
                        Label("Auto-fill", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(detectedVMs.isEmpty)
                }

                TextField("Cluster Name", text: $clusterName)
                    .textFieldStyle(.roundedBorder)

                TextField("Endpoint (https://IP:6443)", text: $endpoint)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Control Planes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $controlPlaneInput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 60)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $workerInput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 60)
                    }
                }

                Button {
                    runManualSetup()
                } label: {
                    Label(manualService.isRunning ? "Running..." : "Run Setup", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualService.isRunning || endpoint.isEmpty || controlPlaneInput.isEmpty)
            }
        }
    }

    private var logsSection: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Progress")
                        .font(.headline)
                        .foregroundStyle(OverlayTheme.textPrimary)

                    Spacer()

                    Button {
                        copyAllLogs()
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .disabled(filteredLogs.isEmpty)
                }

                // Progress bar
                if autoService.isRunning || manualService.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)

                        HStack {
                            Text("Setting up Talos...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(filteredLogs.count) lines")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Last 3 log lines
                VStack(alignment: .leading, spacing: 4) {
                    let lastLogs = Array(filteredLogs.suffix(3))
                    if lastLogs.isEmpty {
                        Text("No activity yet...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(Array(lastLogs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(logColor(for: line))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DashboardPalette.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func copyAllLogs() {
        let allLogs = filteredLogs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allLogs, forType: .string)
    }

    // MARK: - Helpers

    private func updateDetectedVMs() {
        detectedVMs = runningTalosVMs
    }

    private func restoreProgressStage() {
        // If no active run, restore the stage to reflect persisted state
        guard !autoService.isRunning, autoService.currentStage == .idle else { return }
        let talosVMs = VMManager.shared.virtualMachines.filter { $0.selectedDistro == .talos }
        let anyClusterCore = talosVMs.contains { $0.clusterCoreDeployed }
        let anyTalos = talosVMs.contains { $0.talosSetupCompleted }
        if anyClusterCore {
            autoService.currentStage = .completed
        } else if anyTalos {
            autoService.currentStage = .fetchingKubeconfig
        }
    }

    private func autoFillFromDetectedVMs() {
        let masters = detectedVMs.filter { $0.isMaster && isValidIP($0.ipAddress) }
        let workers = detectedVMs.filter { !$0.isMaster && isValidIP($0.ipAddress) }

        if let firstMaster = masters.first {
            endpoint = "https://\(firstMaster.ipAddress):6443"
        }

        controlPlaneInput = masters.map { $0.ipAddress }.joined(separator: "\n")
        workerInput = workers.map { $0.ipAddress }.joined(separator: "\n")
    }

    private func runManualSetup() {
        let controlPlanes = parseNodes(controlPlaneInput)
        let workers = parseNodes(workerInput)

        Task {
            await manualService.configureCluster(
                clusterName: clusterName,
                endpoint: endpoint,
                controlPlaneIPs: controlPlanes,
                workerIPs: workers,
                shouldBootstrap: true,
                shouldFetchKubeconfig: true
            )
        }
    }

    private func runManualBootstrap(_ vm: VirtualMachine) {
        Task {
            // Use manual service to just run bootstrap and fetch kubeconfig
            await TalosAutoSetupService.shared.retrySetup(for: vm)
        }
    }

    private func isValidIP(_ ip: String) -> Bool {
        ip != "Detecting..." && !ip.isEmpty && ip.contains(".")
    }

    private func parseNodes(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func logColor(for log: String) -> Color {
        let lower = log.lowercased()
        if lower.contains("error") || lower.contains("failed") {
            return .red
        } else if lower.contains("warning") || lower.contains("warn") {
            return .yellow
        } else if lower.contains("success") || lower.contains("completed") || lower.contains("ok") {
            return .green
        } else if lower.contains("starting") || lower.contains("[step]") {
            return .cyan
        }
        return OverlayTheme.textPrimary
    }
}
