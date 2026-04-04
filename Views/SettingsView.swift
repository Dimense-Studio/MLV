import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettingsStore.shared
    @State private var updater = AppUpdateManager.shared
    @State private var vmManager = VMManager.shared
    @State private var containerInstallStatus: String? = nil
    @State private var isInstallingContainer = false
    
    private var isContainerMode: Bool {
        settings.workloadRuntime == .appleContainer
    }
    
    var body: some View {
        ZStack {
            OverlayCanvasBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(OverlayTheme.textPrimary)

                    VStack(spacing: 10) {
                        Toggle("Spouštět po přihlášení", isOn: $settings.launchAtLogin)
                        Toggle(isContainerMode ? "Neuspávat Mac při běžících containerech" : "Neuspávat Mac při běžících VM", isOn: $settings.preventSleepWhileVMRunning)
                        Toggle(isContainerMode ? "Automaticky startovat vybrané containery po spuštění aplikace" : "Automaticky startovat vybrané VM po spuštění aplikace", isOn: $settings.autoStartVMsOnLaunch)
                        Toggle("Automaticky aktualizovat aplikaci", isOn: $settings.autoUpdateEnabled)
                    }
                    .padding(16)
                    .overlayPanel(radius: 18)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runtime")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OverlayTheme.textSecondary)

                        Picker("Workload Runtime", selection: $settings.workloadRuntime) {
                            Text("Virtualization.framework").tag(AppSettingsStore.WorkloadRuntime.virtualization)
                            Text("Apple container").tag(AppSettingsStore.WorkloadRuntime.appleContainer)
                        }
                        .pickerStyle(.segmented)

                        Text("Apple container requires the 'container' CLI and active system service (container system start).")
                            .font(.caption)
                            .foregroundStyle(OverlayTheme.textSecondary)

                        HStack(spacing: 10) {
                            Button(vmManager.isAppleContainerToolInstalled() ? "Update Apple Container" : "Install Apple Container") {
                                isInstallingContainer = true
                                containerInstallStatus = nil
                                Task {
                                    do {
                                        try await vmManager.installOrUpdateAppleContainerTool()
                                        containerInstallStatus = "Installer opened. Complete installation in macOS Installer, then switch mode."
                                    } catch {
                                        containerInstallStatus = "Install failed: \(error.localizedDescription)"
                                    }
                                    isInstallingContainer = false
                                }
                            }
                            .disabled(isInstallingContainer)

                            if isInstallingContainer {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let containerInstallStatus {
                            Text(containerInstallStatus)
                                .font(.caption)
                                .foregroundStyle(OverlayTheme.textSecondary)
                        }
                    }
                    .padding(16)
                    .overlayPanel(radius: 18)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Aktualizace")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OverlayTheme.textSecondary)

                        HStack(spacing: 10) {
                            Button("Zkontrolovat nyní") {
                                updater.checkNow()
                            }
                            .disabled(!settings.autoUpdateEnabled)
                            Spacer()
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(OverlayTheme.textSecondary)
                        }

                        if case .downloading = updater.state {
                            ProgressView(value: updater.progress, total: 1.0) {
                                Text("Stahuji aktualizaci...")
                            } currentValueLabel: {
                                Text("\(Int(updater.progress * 100)) %")
                            }
                        } else if case .installing = updater.state {
                            ProgressView(value: 1.0, total: 1.0) {
                                Text("Instaluji aktualizaci...")
                            }
                        }
                    }
                    .padding(16)
                    .overlayPanel(radius: 18)

                    Text("Poznámka: Síťový bridge ve Virtualization.framework je omezený entitlementem. Cluster konektivitu řeš WireGuard overlay.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(14)
                        .overlayPanel(radius: 16)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 520)
    }

    private var statusText: String {
        switch updater.state {
        case .idle:
            return "Neaktivní"
        case .checking:
            return "Kontroluji nové verze..."
        case .updateAvailable(let version):
            return "Nalezena verze \(version)"
        case .downloading(let version):
            return "Stahuji \(version)"
        case .installing(let version):
            return "Instaluji \(version)"
        case .upToDate:
            return "Aplikace je aktuální"
        case .failed(let message):
            return "Chyba: \(message)"
        }
    }
}
