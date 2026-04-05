import Foundation

@Observable
final class VMProvisioningService {
    static let shared = VMProvisioningService()
    
    private init() {}
    
    func provisionIfNeeded(_ vm: VirtualMachine) {
        guard vm.state == .running, vm.isInstalled else { return }
        
        if !vm.k3sInstalled {
            provisionK3s(vm)
        }
        
        if !vm.wireguardConfigured {
            provisionWireGuard(vm)
        }
    }
    
    private func provisionK3s(_ vm: VirtualMachine) {
        let cmd: String
        if vm.isMaster {
            cmd = "curl -sfL https://get.k3s.io | K3S_TOKEN=mlv-cluster-token sh -s - server --cluster-init --write-kubeconfig-mode 644"
        } else {
            // Assume master is at 10.13.0.1 (static IP for control plane)
            cmd = "curl -sfL https://get.k3s.io | K3S_URL=https://10.13.0.1:6443 K3S_TOKEN=mlv-cluster-token sh -"
        }
        
        vm.addLog("Provisioning Kubernetes (K3s)...")
        executeCommand(vm, cmd)
    }
    
    private func provisionWireGuard(_ vm: VirtualMachine) {
        guard let privKey = vm.wgControlPrivateKeyBase64,
              let address = vm.wgControlAddressCIDR else { return }
        
        vm.addLog("Configuring WireGuard mesh network...")
        
        // Build wg0.conf
        var conf = """
[Interface]
PrivateKey = \(privKey)
Address = \(address)
ListenPort = 51820
"""
        
        // Add all VMs in the cluster as peers
        let allVMs = ClusterManager.shared.clusterVMs.filter { $0.id != vm.id }
        let myNodeID = WireGuardManager.shared.hostInfo.id
        
        for peer in allVMs {
            let peerIP = peer.wgAddress.components(separatedBy: "/").first ?? peer.wgAddress
            conf += """

[Peer]
PublicKey = \(peer.publicKey)
AllowedIPs = \(peerIP)/32
"""
            // Determine endpoint
            if peer.nodeID == myNodeID {
                // Peer is on the same host. In NAT mode, guests can talk directly if we know the NAT IP.
                // We'll try to find the actual NAT IP if available.
                if let localPeer = VMManager.shared.virtualMachines.first(where: { $0.id == peer.id }),
                   localPeer.state == .running, 
                   localPeer.ipAddress != "Detecting..." {
                    conf += "\nEndpoint = \(localPeer.ipAddress):51820"
                }
            } else {
                // Peer is on a remote host. Use the host's public/reachable IP and the forwarded port.
                if !peer.hostEndpoint.isEmpty && peer.hostPort > 0 {
                    conf += "\nEndpoint = \(peer.hostEndpoint):\(peer.hostPort)"
                }
            }
            
            conf += "\nPersistentKeepalive = 25"
        }
        
        let base64Conf = Data(conf.utf8).base64EncodedString()
        
        // Script to install WireGuard and setup config
        let script = """
if ! command -v wg &> /dev/null; then
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wireguard wireguard-tools
    elif command -v apk &> /dev/null; then
        apk add wireguard-tools
    fi
fi
mkdir -p /etc/wireguard
echo "\(base64Conf)" | base64 -d > /etc/wireguard/wg0.conf
wg-quick down wg0 &> /dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0 &> /dev/null || true
echo "WG_READY"
"""
        executeCommand(vm, script)
    }

    private func executeCommand(_ vm: VirtualMachine, _ cmd: String) {
        if AppSettingsStore.shared.workloadRuntime == .appleContainer {
            let containerName = "mlv-\(vm.id.uuidString.lowercased().prefix(8))"
            Task {
                do {
                    let result = try await AppleContainerService.shared.execAsync(name: containerName, command: ["/bin/sh", "-c", cmd])
                    await MainActor.run {
                        vm.consoleOutput.append(result.output)
                    }
                } catch {
                    vm.addLog("Container exec failed: \(error.localizedDescription)", isError: true)
                }
            }
        } else {
            writeToSerial(vm, cmd)
        }
    }
    
    private func writeToSerial(_ vm: VirtualMachine, _ cmd: String) {
        guard let data = (cmd + "\n").data(using: .utf8) else { return }
        try? vm.serialWritePipe?.fileHandleForWriting.write(contentsOf: data)
    }
}

extension VirtualMachine {
    var k3sInstalled: Bool {
        return self.consoleOutput.contains("K3S_READY") || self.pods.count > 0 || self.consoleOutput.contains("K3s is up-to-date")
    }
    
    var wireguardConfigured: Bool {
        return self.consoleOutput.contains("WG_READY") || self.consoleOutput.contains("interface: wg0")
    }
}
