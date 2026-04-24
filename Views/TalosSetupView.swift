import SwiftUI

struct TalosSetupView: View {
    let search: String

    @State private var service = TalosSetupService.shared
    @State private var clusterName: String = "mlv-talos"
    @State private var endpoint: String = "https://192.168.1.10:6443"
    @State private var controlPlaneInput: String = "192.168.1.10"
    @State private var workerInput: String = "192.168.1.11\n192.168.1.12"
    @State private var shouldBootstrap: Bool = true
    @State private var shouldFetchKubeconfig: Bool = true

    private var controlPlaneIPs: [String] {
        parseNodes(controlPlaneInput)
    }

    private var workerIPs: [String] {
        parseNodes(workerInput)
    }

    private var filteredLogs: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return service.logs }
        return service.logs.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerPanel

                HStack(alignment: .top, spacing: 14) {
                    configurationPanel
                    executionPanel
                }

                logsPanel
            }
            .padding(16)
        }
        .background(DashboardPalette.surface)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Install talosctl") {
                    TerminalLauncher.openAndRun("brew install siderolabs/tap/talosctl")
                }
            }

            ToolbarItem(placement: .automatic) {
                Button("Open Workspace") {
                    service.openWorkspaceInFinder()
                }
                .disabled(service.lastWorkspacePath.isEmpty)
            }
        }
    }

    private var headerPanel: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Talos Setup")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(OverlayTheme.textPrimary)
                    Spacer()
                    statusChip
                }

                Text("Generate Talos configs into a dedicated workspace folder and provision multiple cluster instances through talosctl.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OverlayTheme.textSecondary)

                HStack(spacing: 10) {
                    metricCard(title: "Control Planes", value: "\(controlPlaneIPs.count)", icon: "server.rack")
                    metricCard(title: "Workers", value: "\(workerIPs.count)", icon: "square.stack.3d.up")
                    metricCard(title: "Workspace", value: service.lastWorkspacePath.isEmpty ? "Not generated" : "Ready", icon: "folder")
                }
            }
        }
    }

    private var configurationPanel: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cluster Definition")
                    .font(.headline)
                    .foregroundStyle(OverlayTheme.textPrimary)

                TextField("Cluster Name", text: $clusterName)
                    .textFieldStyle(.roundedBorder)

                TextField("API Endpoint (https://IP:6443)", text: $endpoint)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Control Plane IPs")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $controlPlaneInput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 90)
                        .padding(8)
                        .background(DashboardPalette.panel.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(DashboardPalette.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Worker IPs")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $workerInput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110)
                        .padding(8)
                        .background(DashboardPalette.panel.opacity(0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(DashboardPalette.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Toggle("Bootstrap cluster after apply-config", isOn: $shouldBootstrap)
                Toggle("Fetch kubeconfig after bootstrap", isOn: $shouldFetchKubeconfig)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var executionPanel: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Execution")
                    .font(.headline)
                    .foregroundStyle(OverlayTheme.textPrimary)

                Text("Operations run with talosctl and stream logs below. A dedicated timestamped folder is created in Application Support/MLV/TalosSetup.")
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)

                HStack(spacing: 8) {
                    Button {
                        Task {
                            await service.configureCluster(
                                clusterName: clusterName,
                                endpoint: endpoint,
                                controlPlaneIPs: controlPlaneIPs,
                                workerIPs: workerIPs,
                                shouldBootstrap: shouldBootstrap,
                                shouldFetchKubeconfig: shouldFetchKubeconfig
                            )
                        }
                    } label: {
                        Label(service.isRunning ? "Running" : "Run Talos Setup", systemImage: service.isRunning ? "hourglass" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isRunning || clusterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controlPlaneIPs.isEmpty)

                    Button("Clear Logs") {
                        service.clearLogs()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.isRunning)
                }

                if let error = service.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Workspace") {
                        Text(service.lastWorkspacePath.isEmpty ? "Not generated yet" : service.lastWorkspacePath)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(OverlayTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    LabeledContent("Pipeline") {
                        Text("gen config → apply controlplane → apply workers → bootstrap → kubeconfig")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(OverlayTheme.textSecondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 400)
    }

    private var logsPanel: some View {
        DashboardPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Talosctl Activity")
                        .font(.headline)
                        .foregroundStyle(OverlayTheme.textPrimary)
                    Spacer()
                    Text("\(filteredLogs.count) lines")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if filteredLogs.isEmpty {
                            Text("No activity yet")
                                .font(.caption)
                                .foregroundStyle(OverlayTheme.textSecondary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(filteredLogs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(OverlayTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 220)
                .background(DashboardPalette.panel.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DashboardPalette.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var statusChip: some View {
        Text(service.isRunning ? "RUNNING" : "READY")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(service.isRunning ? Color.black : OverlayTheme.textPrimary)
            .background(service.isRunning ? Color.green.opacity(0.9) : DashboardPalette.panel)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(DashboardPalette.border, lineWidth: 1)
            )
    }

    private func metricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(OverlayTheme.textSecondary)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(OverlayTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DashboardPalette.panel.opacity(0.35))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DashboardPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func parseNodes(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
