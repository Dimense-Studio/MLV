import Foundation
import AppKit
import Darwin
import os
import SystemConfiguration

struct HostResources {
    private static let logger = Logger(subsystem: "dimense.net.MLV", category: "HostResources")

    static var cpuCount: Int {
        ProcessInfo.processInfo.processorCount
    }
    
    static var totalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    
    static var systemAvailableMemoryMB: Int {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var statistics = vm_statistics64()
        
        host_page_size(hostPort, &pageSize)
        
        let status = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &hostSize)
            }
        }
        
        if status == KERN_SUCCESS {
            // Available = free + inactive + speculative
            let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count)
            return Int((availablePages * UInt64(pageSize)) / (1024 * 1024))
        }
        
        return totalMemoryGB * 1024 - 2048 // Fallback: reserve 2GB
    }
    
    static var freeDiskSpaceGB: Int {
        let path = NSHomeDirectory()
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeSize = systemAttributes[.systemFreeSize] as? NSNumber {
                return Int(freeSize.int64Value / (1024 * 1024 * 1024))
            }
        } catch {
            logger.error("Error getting free disk space: \(error.localizedDescription, privacy: .public)")
        }
        return 0
    }
    
    struct NetworkInterface: Identifiable {
        let id = UUID()
        let name: String
        let type: InterfaceType
        let speed: String
        let bsdName: String
        var isActive: Bool = false
        
        enum InterfaceType {
            case ethernet, thunderbolt, wifi, unknown
            
            var icon: String {
                switch self {
                case .ethernet: return "cable.connector"
                case .thunderbolt: return "bolt.horizontal.fill"
                case .wifi: return "wifi"
                case .unknown: return "network"
                }
            }
        }
    }
    
    static func getNetworkInterfaces() -> [NetworkInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var byName: [String: Bool] = [:]
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            let isUp = (ptr.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            let isRunning = (ptr.pointee.ifa_flags & UInt32(IFF_RUNNING)) != 0
            byName[name] = (byName[name] ?? false) || (isUp && isRunning)
        }

        var interfaces: [NetworkInterface] = byName.keys.sorted().map { bsd in
            let type: NetworkInterface.InterfaceType
            let name: String
            if bsd.hasPrefix("en") {
                type = bsd == "en0" ? .wifi : .ethernet
                name = bsd == "en0" ? "Wi-Fi" : "Ethernet (\(bsd))"
            } else if bsd.hasPrefix("bridge") {
                type = .thunderbolt
                name = "Bridge (\(bsd))"
            } else {
                type = .unknown
                name = "Interface \(bsd)"
            }
            return NetworkInterface(
                name: name,
                type: type,
                speed: "N/A",
                bsdName: bsd,
                isActive: byName[bsd] ?? false
            )
        }

        interfaces.removeAll { iface in
            iface.bsdName == "lo0" ||
            iface.bsdName.hasPrefix("utun") ||
            iface.bsdName.hasPrefix("awdl") ||
            iface.bsdName.hasPrefix("llw")
        }
        interfaces.removeAll { !$0.isActive && $0.type == .unknown }
        return interfaces
    }

    static func ipAddress(for bsdName: String) -> String? {
        getIPAddress(for: bsdName)
    }
    
    static func preferredIPv4Address(preferredTypes: [NetworkInterface.InterfaceType]) -> String? {
        let active = getNetworkInterfaces().filter { $0.isActive }
        for t in preferredTypes {
            if let match = active.first(where: { $0.type == t }),
               let ip = ipAddress(for: match.bsdName),
               !ip.isEmpty {
                return ip
            }
        }
        return active.compactMap { ipAddress(for: $0.bsdName) }.first
    }

    static func preferredActiveInterfaceType(preferredTypes: [NetworkInterface.InterfaceType]) -> NetworkInterface.InterfaceType {
        let active = getNetworkInterfaces().filter { $0.isActive }
        for t in preferredTypes {
            if active.contains(where: { $0.type == t }) {
                return t
            }
        }
        return active.first?.type ?? .unknown
    }

    static func primaryIPv4InterfaceBSDName() -> String? {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        if let primary = global["PrimaryInterface"] as? String, !primary.isEmpty {
            return primary
        }
        return nil
    }

    private static func getIPAddress(for interface: String) -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interfaceName = String(cString: ptr.pointee.ifa_name)
            if interfaceName == interface {
                let addr = ptr.pointee.ifa_addr.pointee
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }
}
