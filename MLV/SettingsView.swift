import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettingsStore.shared
    
    var body: some View {
        Form {
            Toggle("Spouštět po přihlášení", isOn: $settings.launchAtLogin)
            
            Toggle("Neuspávat Mac při běžících VM", isOn: $settings.preventSleepWhileVMRunning)
            
            Toggle("Automaticky startovat vybrané VM po spuštění aplikace", isOn: $settings.autoStartVMsOnLaunch)
            
            Text("Poznámka: Síťový bridge ve Virtualization.framework je omezený entitlementem. Cluster konektivitu řeš WireGuard overlay.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 520)
    }
}
