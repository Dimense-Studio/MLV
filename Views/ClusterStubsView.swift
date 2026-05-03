import SwiftUI

struct RoleSelectionView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose Cluster Role")
                .font(.headline)

            Button("Control Plane") {
                ClusterConfiguration.shared.setRole(.controlPlane)
                isPresented = false
            }

            Button("Worker") {
                ClusterConfiguration.shared.setRole(.worker)
                isPresented = false
            }
        }
        .padding()
        .frame(minWidth: 320)
    }
}

struct ClusterSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cluster Settings")
                .font(.headline)

            Text("Role: \(ClusterConfiguration.shared.currentRole?.rawValue ?? "Not selected")")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 360, minHeight: 220)
    }
}

struct ClusterDashboardView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Cluster Dashboard")
                .font(.title3)
            Text("Cluster features are available.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
