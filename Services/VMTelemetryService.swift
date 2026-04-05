import Foundation
import SwiftUI

@Observable
final class VMTelemetryService {
    static let shared = VMTelemetryService()
    
    private init() {}
    
    func generatePollCommand(for vm: VirtualMachine) -> String {
        let normalizedVMName = vm.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let autoPattern = "mlv-\(normalizedVMName)"
        let processPattern = vm.monitoredProcessName.isEmpty ? autoPattern : vm.monitoredProcessName
        let shellProcessPattern = shellSingleQuoted(processPattern)
        
        return """
        echo "---POLL_START---"
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
        mkdir -p /mnt/mlvshare 2>/dev/null || true
        if ! mountpoint -q /mnt/mlvshare 2>/dev/null; then
          modprobe virtiofs 2>/dev/null || true
          mount -t virtiofs mlvshare /mnt/mlvshare 2>/dev/null || \
          mount -t virtiofs none /mnt/mlvshare -o source=mlvshare 2>/dev/null || \
          mount -t 9p -o trans=virtio,version=9p2000.L mlvshare /mnt/mlvshare 2>/dev/null || true
        fi
        ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n 1
        ip route show default | awk '{print $3}' | head -n 1
        cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}' | xargs echo
        echo "---VM_USAGE_START---"
        awk '/^cpu / {print "CPU_TICKS " $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8 " " $9; exit}' /proc/stat 2>/dev/null || echo "CPU_TICKS 0 0 0 0 0 0 0 0"
        awk '/^MemTotal:/ {total=$2} /^MemAvailable:/ {avail=$2} END {if (total>0) print "MEM_KB " total " " avail; else print "MEM_KB 0 0"}' /proc/meminfo 2>/dev/null
        df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print "DISK_PCT " $5}' || echo "DISK_PCT 0"
        PID=\(max(0, vm.monitoredProcessPID))
        if [ "$PID" -le 1 ] || [ ! -r "/proc/$PID/stat" ]; then
          PID=$(pgrep -fo -- \(shellProcessPattern) 2>/dev/null || echo 0)
        fi
        echo "PID_SELECTED $PID"
        if [ "$PID" -gt 0 ] && [ -r "/proc/$PID/stat" ]; then
          awk -v pid="$PID" '$1 == pid {print "PID_TICKS " $14 " " $15; found=1} END {if (!found) print "PID_TICKS 0 0"}' /proc/$PID/stat 2>/dev/null
          awk -v pid="$PID" '/^VmRSS:/ {print "PID_RSS_KB " $2; found=1} END {if (!found) print "PID_RSS_KB 0"}' /proc/$PID/status 2>/dev/null
        else
          echo "PID_TICKS 0 0"
          echo "PID_RSS_KB 0"
        fi
        echo "---VM_USAGE_END---"
        echo "---PODS_START---"
        KUBECTL_BIN="$(command -v kubectl 2>/dev/null || true)"
        if [ -z "$KUBECTL_BIN" ] && [ -x /usr/local/bin/kubectl ]; then KUBECTL_BIN=/usr/local/bin/kubectl; fi
        if [ -n "$KUBECTL_BIN" ]; then
          "$KUBECTL_BIN" get pods -A --no-headers -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CPU:.spec.containers[0].resources.requests.cpu,RAM:.spec.containers[0].resources.requests.memory" | awk '{print $1 "|" $2 "|" $3 "|" $4 "|" $5}' | head -n 40
        else
          echo "K3S_NOT_READY"
        fi
        echo "---PODS_END---"
        echo "---CONTAINERS_START---"
        CR_BIN=""
        for b in docker nerdctl podman crictl; do
           CR_BIN="$(command -v $b 2>/dev/null || true)"
           if [ -n "$CR_BIN" ]; then break; fi
        done
        if [ -n "$CR_BIN" ]; then
           case "$CR_BIN" in
              *docker*) "$CR_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|docker' 2>/dev/null | head -n 40 ;;
              *nerdctl*) "$CR_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|nerdctl' 2>/dev/null | head -n 40 ;;
              *podman*) "$CR_BIN" ps --format '{{.Names}}|{{.Image}}|{{.Status}}|podman' 2>/dev/null | head -n 40 ;;
              *crictl*) "$CR_BIN" ps --no-trunc 2>/dev/null | awk 'NR>1 {print $NF "|" $2 "|" $5 "|" "crictl"}' | head -n 40 ;;
           esac
        else
           echo "CONTAINERS_NOT_READY"
        fi
        echo "---CONTAINERS_END---"
        echo "---POLL_END---"
        """
    }

    private func shellSingleQuoted(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
