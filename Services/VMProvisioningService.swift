import Foundation

@Observable
final class VMProvisioningService {
    static let shared = VMProvisioningService()

    private init() {}

    func provisionIfNeeded(_ vm: VirtualMachine) {
        guard vm.state == .running, vm.isInstalled else { return }
        
        // Talos is an immutable OS - use Talos-specific provisioning
        if vm.selectedDistro == .talos {
            if !vm.talosClusterConfigured {
                provisionTalosCluster(vm)
            } else if !vm.longhornDiskConfigured {
                provisionTalosNode(vm, role: vm.isMaster ? "master" : "node")
            }
            return
        }

        if !vm.k3sInstalled {
            provisionK3s(vm)
        }

        if !vm.longhornDiskConfigured {
            provisionLonghornDisk(vm)
        }

        if !vm.wireguardConfigured {
            provisionWireGuard(vm)
        }

        provisionNetworkHealthChecks(vm)
    }

    private func provisionTalosCluster(_ vm: VirtualMachine) {
        vm.addLog("Detecting Talos cluster configuration...")

        let script = """
        set -euo pipefail

        echo "=== Disk Detection ==="
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

        # /dev/vda is SYSTEM disk - DO NOT USE
        # /dev/vdb is DATA disk (if present)
        if [ ! -b /dev/vdb ]; then
            echo "No extra data disk (/dev/vdb) found - Longhorn storage NOT available"
            echo "Only /dev/vda (system) is available - DO NOT use for storage"
            exit 0
        fi

        echo "=== Data disk detected: /dev/vdb ==="
        echo "This disk will be used for /data/longhorn (Longhorn storage)"
        echo "TALOS_EXTRA_DISK_FOUND"
        """

        executeCommand(vm, script)
    }

    private func provisionTalosNode(_ vm: VirtualMachine, role: String) {
        let script = """
        set -euo pipefail

        # IMPORTANT: Only touch /dev/vdb (data disk) - NEVER touch /dev/vda (system disk)!
        if [ ! -b /dev/vdb ]; then
            echo "No data disk (/dev/vdb) - cannot set up Longhorn storage"
            exit 0
        fi

        # Check if already configured
        if mountpoint -q /data/longhorn 2>/dev/null; then
            echo "Longhorn disk already mounted at /data/longhorn"
            echo "TALOS_LONGHORN_DISK_READY"
            exit 0
        fi

        echo "=== Setting up data disk /dev/vdb for Longhorn ==="

        # Wipe any existing filesystem signature (CAREFUL: only /dev/vdb!)
        wipefs -a /dev/vdb 2>/dev/null || true

        # Format as ext4
        mkfs.ext4 -F /dev/vdb

        # Get UUID
        UUID=$(blkid -s UUID -o value /dev/vdb)
        echo "Formatted /dev/vdb with UUID: $UUID"

        # Create mount point
        mkdir -p /data/longhorn

        # Add to fstab (CAREFUL: only /dev/vdb!)
        if ! grep -q "UUID=$UUID" /etc/fstab; then
            echo "UUID=$UUID /data/longhorn ext4 defaults,nofail 0 2" >> /etc/fstab
        fi

        # Mount
        mount /data/longhorn

        echo "=== Longhorn storage ready at /data/longhorn ==="
        echo "TALOS_LONGHORN_DISK_READY"
        """

        vm.addLog("Setting up Talos Longhorn storage on /dev/vdb...")
        executeCommand(vm, script)
    }

    private func provisionK3s(_ vm: VirtualMachine) {
        let expectedSubnet = VMNetworkService.shared.subnetPrefix(forIPAddress: vm.ipAddress)
            ?? VMNetworkService.shared.primaryClusterSubnetPrefix()
            ?? ""

        let masterIP = resolveMasterNodeIP(for: vm)

        let installCommand: String
        if vm.isMaster {
            installCommand = """
            curl -sfL https://get.k3s.io | K3S_TOKEN=mlv-cluster-token INSTALL_K3S_EXEC='server --cluster-init --write-kubeconfig-mode 644 --disable-network-policy' sh -
            """
        } else if let masterIP {
            installCommand = """
            curl -sfL https://get.k3s.io | K3S_URL=https://\(masterIP):6443 K3S_TOKEN=mlv-cluster-token INSTALL_K3S_EXEC='agent' sh -
            """
        } else {
            vm.addLog("Skipping k3s install: unable to resolve master node IP on primary bridged network.", isError: true)
            return
        }

        let script = """
        set -euo pipefail

        detect_iface() {
          local iface
          iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}') || true
          if [ -z "$iface" ]; then
            iface=$(ip -o -4 addr show scope global | awk '{print $2; exit}') || true
          fi
          echo "$iface"
        }

        detect_ip() {
          local iface="$1"
          if [ -n "$iface" ]; then
            ip -4 -o addr show dev "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1
          fi
        }

        PRIMARY_IFACE=$(detect_iface)
        PRIMARY_IP=$(detect_ip "$PRIMARY_IFACE")

        if [ -z "$PRIMARY_IFACE" ] || [ -z "$PRIMARY_IP" ]; then
          echo "Failed to determine primary network interface for k3s"
          exit 1
        fi

        mkdir -p /etc/rancher/k3s
        cat >/etc/rancher/k3s/config.yaml <<EOF
        node-ip: "$PRIMARY_IP"
        node-external-ip: "$PRIMARY_IP"
        flannel-iface: "$PRIMARY_IFACE"
        kubelet-arg:
          - "node-ip=$PRIMARY_IP"
        EOF

        \(installCommand)

        if [ -n "\(expectedSubnet)" ]; then
          CURRENT_SUBNET=$(echo "$PRIMARY_IP" | awk -F. '{print $1"."$2"."$3}')
          if [ "$CURRENT_SUBNET" != "\(expectedSubnet)" ]; then
            echo "Subnet mismatch: expected \(expectedSubnet), got $CURRENT_SUBNET"
            systemctl stop k3s 2>/dev/null || true
            systemctl stop k3s-agent 2>/dev/null || true
            exit 1
          fi
        fi

        if systemctl is-enabled k3s >/dev/null 2>&1; then
          systemctl restart k3s
        fi
        if systemctl is-enabled k3s-agent >/dev/null 2>&1; then
          systemctl restart k3s-agent
        fi

        echo "K3S_READY"
        """

        vm.addLog("Provisioning Kubernetes (k3s) using bridged primary interface...")
        executeCommand(vm, script)
    }

    private func provisionLonghornDisk(_ vm: VirtualMachine) {
        let script = """
        set -euo pipefail

        if [ ! -b /dev/vdb ]; then
          echo "Longhorn disk skipped: /dev/vdb not present"
          exit 0
        fi

        if ! blkid /dev/vdb >/dev/null 2>&1; then
          mkfs.ext4 -F /dev/vdb
        fi

        mkdir -p /data
        UUID=$(blkid -s UUID -o value /dev/vdb)
        grep -q "UUID=$UUID /data " /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
        mountpoint -q /data || mount /data
        mkdir -p /data/longhorn

        if command -v kubectl >/dev/null 2>&1; then
          kubectl label node "$(hostname)" node.longhorn.io/create-default-disk=true --overwrite >/dev/null 2>&1 || true
          kubectl annotate node "$(hostname)" node.longhorn.io/default-disks-config='[{"path":"/data/longhorn","allowScheduling":true}]' --overwrite >/dev/null 2>&1 || true
        fi

        echo "LONGHORN_DISK_READY"
        """

        vm.addLog("Preparing dedicated Longhorn block disk on /dev/vdb and mounting /data...")
        executeCommand(vm, script)
    }

    private func provisionNetworkHealthChecks(_ vm: VirtualMachine) {
        let expectedSubnet = VMNetworkService.shared.subnetPrefix(forIPAddress: vm.ipAddress)
            ?? VMNetworkService.shared.primaryClusterSubnetPrefix()
            ?? ""

        let peerIPs = resolvePeerPrimaryIPs(for: vm)
        let peersCSV = peerIPs.joined(separator: ",")

        let script = """
        set -euo pipefail

        cat >/usr/local/bin/mlv-net-health.sh <<'EOF'
        #!/bin/sh
        set -eu

        EXPECTED_SUBNET="\(expectedSubnet)"
        PEERS="\(peersCSV)"

        iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
        ipaddr=""
        if [ -n "$iface" ]; then
          ipaddr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1)
        fi

        if [ -n "$EXPECTED_SUBNET" ] && [ -n "$ipaddr" ]; then
          subnet=$(echo "$ipaddr" | awk -F. '{print $1"."$2"."$3}')
          if [ "$subnet" != "$EXPECTED_SUBNET" ]; then
            logger -t mlv-net-health "subnet drift detected ($subnet != $EXPECTED_SUBNET), stopping k3s services"
            systemctl stop k3s 2>/dev/null || true
            systemctl stop k3s-agent 2>/dev/null || true
            exit 1
          fi
        fi

        failed=0
        if [ -n "$PEERS" ]; then
          OLDIFS="$IFS"
          IFS=','
          for peer in $PEERS; do
            [ -z "$peer" ] && continue
            if ! ping -c 2 -W 2 "$peer" >/dev/null 2>&1; then
              failed=$((failed + 1))
            fi
          done
          IFS="$OLDIFS"
        fi

        if [ "$failed" -gt 0 ]; then
          logger -t mlv-net-health "$failed peer reachability checks failed"
        fi
        EOF

        chmod +x /usr/local/bin/mlv-net-health.sh

        cat >/etc/systemd/system/mlv-net-health.service <<'EOF'
        [Unit]
        Description=MLV network health check

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/mlv-net-health.sh
        EOF

        cat >/etc/systemd/system/mlv-net-health.timer <<'EOF'
        [Unit]
        Description=Run MLV network health check every 30 seconds

        [Timer]
        OnBootSec=20s
        OnUnitActiveSec=30s
        Unit=mlv-net-health.service

        [Install]
        WantedBy=timers.target
        EOF

        systemctl daemon-reload
        systemctl enable --now mlv-net-health.timer
        """

        executeCommand(vm, script)
    }

    private func provisionWireGuard(_ vm: VirtualMachine) {
        guard let privKey = vm.wgControlPrivateKeyBase64,
              let address = vm.wgControlAddressCIDR else { return }

        vm.addLog("Configuring WireGuard control-plane fallback network (no storage/data routing)...")

        var conf = """
[Interface]
PrivateKey = \(privKey)
Address = \(address)
ListenPort = 51820
"""

        let allVMs = ClusterManager.shared.clusterVMs.filter { $0.id != vm.id }
        let myNodeID = WireGuardManager.shared.hostInfo.id

        for peer in allVMs {
            let peerIP = peer.wgAddress.components(separatedBy: "/").first ?? peer.wgAddress
            conf += """

[Peer]
PublicKey = \(peer.publicKey)
AllowedIPs = \(peerIP)/32
"""

            if peer.nodeID == myNodeID,
               let localPeer = VMManager.shared.virtualMachines.first(where: { $0.id == peer.id }),
               localPeer.state == .running,
               localPeer.ipAddress != "Detecting..." {
                conf += "\nEndpoint = \(localPeer.ipAddress):51820"
            } else if !peer.hostEndpoint.isEmpty && peer.hostPort > 0 {
                conf += "\nEndpoint = \(peer.hostEndpoint):\(peer.hostPort)"
            }

            conf += "\nPersistentKeepalive = 25"
        }

        let base64Conf = Data(conf.utf8).base64EncodedString()

        let script = """
if ! command -v wg >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y wireguard wireguard-tools
    elif command -v apk >/dev/null 2>&1; then
        apk add wireguard-tools
    fi
fi
mkdir -p /etc/wireguard
echo "\(base64Conf)" | base64 -d > /etc/wireguard/wg0.conf
wg-quick down wg0 >/dev/null 2>&1 || true
wg-quick up wg0
systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
echo "WG_READY"
"""
        executeCommand(vm, script)
    }

    private func resolveMasterNodeIP(for vm: VirtualMachine) -> String? {
        let preferredSubnet = VMNetworkService.shared.subnetPrefix(forIPAddress: vm.ipAddress)

        if let localMaster = VMManager.shared.virtualMachines.first(where: { $0.isMaster && $0.state == .running && $0.ipAddress != "Detecting..." }) {
            return localMaster.ipAddress
        }

        let remoteMasters = ClusterManager.shared.clusterVMs.filter {
            $0.id != vm.id && $0.isMaster && ($0.primaryAddress?.isEmpty == false)
        }

        if let preferredSubnet,
           let inSubnet = remoteMasters.first(where: {
               guard let ip = $0.primaryAddress else { return false }
               return VMNetworkService.shared.subnetPrefix(forIPAddress: ip) == preferredSubnet
           }) {
            return inSubnet.primaryAddress
        }

        return remoteMasters.first?.primaryAddress
    }

    private func resolvePeerPrimaryIPs(for vm: VirtualMachine) -> [String] {
        let localPeers = VMManager.shared.virtualMachines
            .filter { $0.id != vm.id && $0.state == .running && $0.ipAddress != "Detecting..." }
            .map(\.ipAddress)

        let remotePeers = ClusterManager.shared.clusterVMs
            .filter { $0.id != vm.id }
            .compactMap(\.primaryAddress)

        return Array(Set(localPeers + remotePeers)).sorted()
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
        self.consoleOutput.contains("K3S_READY") || self.pods.count > 0 || self.consoleOutput.contains("K3s is up-to-date")
    }

    var wireguardConfigured: Bool {
        self.consoleOutput.contains("WG_READY") || self.consoleOutput.contains("interface: wg0")
    }

    var longhornDiskConfigured: Bool {
        self.consoleOutput.contains("LONGHORN_DISK_READY") || self.consoleOutput.contains("TALOS_LONGHORN_DISK_READY")
    }

    var talosClusterConfigured: Bool {
        self.consoleOutput.contains("TALOS_EXTRA_DISK_READY")
    }
}
