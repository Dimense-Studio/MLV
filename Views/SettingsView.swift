import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettingsStore.shared
    @State private var updater = AppUpdateManager.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("Spouštět po přihlášení", isOn: $settings.launchAtLogin)
                Toggle("Neuspávat Mac při běžících VM", isOn: $settings.preventSleepWhileVMRunning)
                Toggle("Automaticky startovat vybrané VM po spuštění aplikace", isOn: $settings.autoStartVMsOnLaunch)
                Toggle("Automaticky aktualizovat aplikaci", isOn: $settings.autoUpdateEnabled)
            }
            
            Section("Aktualizace") {
                HStack(spacing: 10) {
                    Button("Zkontrolovat nyní") {
                        updater.checkNow()
                    }
                    .disabled(!settings.autoUpdateEnabled)
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section {
                Text("Poznámka: Síťový bridge ve Virtualization.framework je omezený entitlementem. Cluster konektivitu řeš WireGuard overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480)
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
