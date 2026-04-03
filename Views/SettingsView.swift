import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettingsStore.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("Spouštět po přihlášení", isOn: $settings.launchAtLogin)
                Toggle("Neuspávat Mac při běžících VM", isOn: $settings.preventSleepWhileVMRunning)
                Toggle("Automaticky startovat vybrané VM po spuštění aplikace", isOn: $settings.autoStartVMsOnLaunch)
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
}
