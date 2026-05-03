import Foundation
import Virtualization
import Darwin

@Observable
final class VMNetworkService {
    static let shared = VMNetworkService()

    struct BridgeSelection {
        let identifier: String
        let ipv4Address: String
        let subnetPrefix: String
    }

    private init() {}

    func allocateWireGuardPorts(for id: UUID) -> (control: Int, data: Int) {
        let suffix = Int(id.uuidString.suffix(4), radix: 16) ?? Int.random(in: 0...9999)
        let control = 30000 + (suffix % 10000)
        let data = 40000 + (suffix % 10000)
        return (control, data)
    }

    func allocateWireGuardOctet(for id: UUID, preferred: Int?) -> Int {
        if let preferred { return preferred }
        let suffix = Int(id.uuidString.suffix(2), radix: 16) ?? Int.random(in: 10...250)
        let octet = (suffix % 220) + 10
        return octet
    }

    func resolveBridgeInterface(preferred: String?) -> String? {
        resolveBridgeSelection(
            preferred: preferred,
            requiredSubnetPrefix: primaryClusterSubnetPrefix(),
            clusterSubnetPrefix: primaryClusterSubnetPrefix()
        )?.identifier
    }

    func resolveBridgeSelection(
        preferred: String?,
        requiredSubnetPrefix: String?,
        clusterSubnetPrefix: String?
    ) -> BridgeSelection? {
        let availableBridged = VZBridgedNetworkInterface.networkInterfaces
        guard !availableBridged.isEmpty else { return nil }

        let candidates: [BridgeSelection] = availableBridged.compactMap { bridged in
            guard let ip = ipv4Address(forBSDName: bridged.identifier),
                  let subnet = subnetPrefix(forIPAddress: ip) else {
                return nil
            }
            return BridgeSelection(identifier: bridged.identifier, ipv4Address: ip, subnetPrefix: subnet)
        }

        guard !candidates.isEmpty else { return nil }

        if let preferred, !preferred.isEmpty,
           let exact = candidates.first(where: { $0.identifier == preferred }),
           requiredSubnetPrefix == nil || exact.subnetPrefix == requiredSubnetPrefix {
            return exact
        }

        if let primaryBSD = HostResources.bestAvailableInterface()?.bsdName,
           let primaryCandidate = candidates.first(where: { $0.identifier == primaryBSD }) {
            return primaryCandidate
        }

        let sorted = candidates.sorted { lhs, rhs in
            let leftPriority = interfacePriority(identifier: lhs.identifier)
            let rightPriority = interfacePriority(identifier: rhs.identifier)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return lhs.identifier < rhs.identifier
        }

        if let requiredSubnetPrefix,
           let sameSubnet = sorted.first(where: { $0.subnetPrefix == requiredSubnetPrefix }) {
            return sameSubnet
        }

        if let clusterSubnetPrefix,
           let clusterMatch = sorted.first(where: { $0.subnetPrefix == clusterSubnetPrefix }) {
            return clusterMatch
        }

        return sorted.first
    }

    func primaryClusterSubnetPrefix() -> String? {
        var scores: [String: Int] = [:]

        for vm in ClusterManager.shared.clusterVMs {
            guard let primaryAddress = vm.primaryAddress,
                  let prefix = subnetPrefix(forIPAddress: primaryAddress) else {
                continue
            }
            scores[prefix, default: 0] += 1
        }

        return scores.max(by: { $0.value < $1.value })?.key
    }

    func subnetPrefix(forIPAddress ipAddress: String) -> String? {
        let octets = ipAddress.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2])"
    }

    private func interfacePriority(identifier: String) -> Int {
        if identifier.localizedCaseInsensitiveContains("bridge") || identifier.localizedCaseInsensitiveContains("thunderbolt") {
            return 0
        }
        if identifier.hasPrefix("en") {
            return 1
        }
        return 3
    }

    private func ipv4Address(forBSDName bsdName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == bsdName else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty, !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                return ip
            }
        }
        return nil
    }
}
