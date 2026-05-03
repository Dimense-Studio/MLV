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
            // Improved detection: check for Thunderbolt bridge via IORegistry or interface name patterns
            if bsd.hasPrefix("bridge") {
                // Check if this bridge is a Thunderbolt bridge by looking at its members
                if isThunderboltBridge(bsdName: bsd) {
                    type = .thunderbolt
                    name = "Thunderbolt Bridge (\(bsd))"
                } else {
                    type = .ethernet
                    name = "Bridge (\(bsd))"
                }
            } else if bsd.hasPrefix("en") {
                // en0 is typically WiFi on Macs, but can be Ethernet on some configs
                // Use SystemConfiguration to determine primary interface type
                if bsd == "en0", isWiFiInterface(bsdName: bsd) {
                    type = .wifi
                    name = "Wi-Fi (\(bsd))"
                } else {
                    type = .ethernet
                    name = "Ethernet (\(bsd))"
                }
            } else {
                type = .unknown
                name = "Interface \(bsd)"
            }
            return NetworkInterface(
                name: name,
                type: type,
                speed: detectSpeed(for: bsd),
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

    // MARK: - Interface Detection Helpers

    /// Check if a bridge interface is a Thunderbolt bridge by examining its member interfaces
    private static func isThunderboltBridge(bsdName: String) -> Bool {
        // Use sysctl or ifconfig to get bridge member interfaces
        // For simplicity, check if any member is a Thunderbolt interface
        // Typically Thunderbolt bridges include interfaces like 'en2' that are Thunderbolt Ethernet
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [bsdName]
        process.standardOutput = pipe
        process.standardError = Pipe() // discard errors
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        // Look for member interfaces that are likely Thunderbolt (e.g., en interfaces that are not en0/en1)
        // This is a heuristic; a more robust method would use IOKit
        if output.contains("member:") {
            // Check if any member interface is not the primary WiFi/Ethernet
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                if line.contains("member:") {
                    let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                    for part in parts {
                        if part.hasPrefix("en"), part != "en0", part != "en1" {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Check if an interface is WiFi using SystemConfiguration
    private static func isWiFiInterface(bsdName: String) -> Bool {
        guard let dynamicStore = SCDynamicStoreCreate(nil, "MLV" as CFString, nil, nil) else { return false }
        let pattern = "State:/Network/Interface/\(bsdName)" as CFString
        guard let value = SCDynamicStoreCopyValue(dynamicStore, pattern) else { return false }
        if let dict = value as? [String: Any],
           let hardware = dict["SCNetworkInterfaceInfo"] as? [String: Any],
           let type = hardware["SCNetworkInterfaceType"] as? String {
            return type == "IEEE80211"
        }
        return bsdName == "en0" // Fallback: assume en0 is WiFi
    }

    /// Detect link speed for an interface (best-effort)
    private static func detectSpeed(for bsdName: String) -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getMedia", bsdName]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return "N/A" }
        // Parse for speed like "1000baseT" or "10 Gbit/s"
        if output.contains("1000baseT") || output.contains("1000BASE-T") {
            return "1 Gbps"
        } else if output.contains("10GBase") || output.contains("10 Gbit") {
            return "10 Gbps"
        } else if output.contains("100baseTX") {
            return "100 Mbps"
        } else if output.contains("autoselect") {
            return "Auto"
        }
        return "N/A"
    }

    // MARK: - Active Interface with Priority

    /// Returns active interfaces sorted by priority: Thunderbolt > Ethernet > WiFi > unknown
    static func activeInterfacesWithPriority() -> [(interface: NetworkInterface, ipv4: String?)] {
        let active = getNetworkInterfaces().filter { $0.isActive }
        let withIPs = active.map { iface -> (NetworkInterface, String?) in
            let ip = ipAddress(for: iface.bsdName)
            return (iface, ip)
        }
        return withIPs.sorted { a, b in
            let priorityA = interfacePriority(iface: a.0)
            let priorityB = interfacePriority(iface: b.0)
            if priorityA != priorityB { return priorityA < priorityB }
            // Secondary sort by name
            return a.0.bsdName < b.0.bsdName
        }
    }

    private static func interfacePriority(iface: NetworkInterface) -> Int {
        switch iface.type {
        case .thunderbolt: return 0
        case .ethernet: return 1
        case .wifi: return 2
        case .unknown: return 3
        }
    }

    /// Returns the best available interface type and IP based on priority
    static func bestAvailableInterface() -> (type: NetworkInterface.InterfaceType, bsdName: String, ipv4: String)? {
        let sorted = activeInterfacesWithPriority()
        guard let first = sorted.first, let ip = first.1, !ip.isEmpty else { return nil }
        return (first.0.type, first.0.bsdName, ip)
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
