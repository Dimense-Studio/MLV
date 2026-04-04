import Foundation

@Observable
final class VMProvisioningService {
    static let shared = VMProvisioningService()
    
    private init() {}
    
    func provisionIfNeeded(_ vm: VirtualMachine) {
        guard vm.state == .running, vm.isInstalled else { return }
        guard !vm.k3sInstalled else { return }
        
        let cmd: String
        if vm.isMaster {
            cmd = "curl -sfL https://get.k3s.io | K3S_TOKEN=mlv-cluster-token sh -s - server --cluster-init --write-kubeconfig-mode 644"
        } else {
            // In a real scenario, we'd get the master's IP and token via ClusterManager.
            // For now, assume a static token and try to join the master if it exists.
            cmd = "curl -sfL https://get.k3s.io | K3S_URL=https://10.13.0.1:6443 K3S_TOKEN=mlv-cluster-token sh -"
        }
        
        vm.addLog("Provisioning Kubernetes (K3s)...")
        if let data = (cmd + "\n").data(using: .utf8) {
            try? vm.serialWritePipe?.fileHandleForWriting.write(contentsOf: data)
        }
    }
}

extension VirtualMachine {
    var k3sInstalled: Bool {
        // This is a placeholder; we should set this when polling detects k3s.
        return self.consoleOutput.contains("K3S_READY") || self.pods.count > 0
    }
}
