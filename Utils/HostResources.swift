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
            let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count)
            return Int((availablePages * UInt64(pageSize)) / (1024 * 1024))
        }
        
        return totalMemoryGB * 1024 - 2048
    }
    
    static var freeDiskSpaceGB: Int {
        let path = NSHomeDirectory()
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeSize = systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber {
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
        
        enum InterfaceType: String, CaseIterable {
            case ethernet = "Ethernet"
            case thunderbolt = "Thunderbolt"
            case wifi = "WiFi"
            case unknown = "Unknown"
            
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
    
    // MARK: - Primary IP Detection (Simplified & Debuggable)
    
    /// Get the device's primary LAN IPv4 address.
    /// This is what should show in the topology (e.g., 192.168.2.11).
    static func deviceIPv4Address() -> String? {
        // Method 1: Use SystemConfiguration to get the primary interface's IP
        if let ip = primaryInterfaceIP_SystemConfig() {
            logger.info("[deviceIPv4] SystemConfig returned: \(ip)")
            return ip
        }
        
        // Method 2: Use ifconfig to find active interface with non-NAT IP
        if let ip = deviceIPv4_ifconfig() {
            logger.info("[deviceIPv4] ifconfig returned: \(ip)")
            return ip
        }
        
        // Method 3: Scan all active interfaces, skip NAT/loopback
        if let ip = deviceIPv4_scanInterfaces() {
            logger.info("[deviceIPv4] Scan returned: \(ip)")
            return ip
        }
        
        logger.warning("[deviceIPv4] All methods failed, returning nil")
        return nil
    }
    
    /// Method 1: Use SystemConfiguration (most reliable)
    private static func primaryInterfaceIP_SystemConfig() -> String? {
        let store = SCDynamicStoreCreate(kCFAllocatorDefault, "MLV" as CFString, nil, nil)
        guard let store = store else {
            logger.error("[primaryIP] Failed to create SCDynamicStore")
            return nil
        }
        
        // Get primary interface name
        guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) else {
            logger.warning("[primaryIP] No Global IPv4 found")
            return nil
        }
        guard let globalDict = unsafeBitCast(global, to: NSDictionary.self) as? [String: Any] else {
            return nil
        }
        guard let primaryInterface = globalDict["PrimaryInterface"] as? String, !primaryInterface.isEmpty else {
            logger.warning("[primaryIP] No PrimaryInterface in Global IPv4")
            return nil
        }
        
        logger.info("[primaryIP] Primary interface: \(primaryInterface)")
        
        // Get IP for this interface
        let pattern = "State:/Network/Interface/\(primaryInterface)/IPv4" as CFString
        guard let ifaceValue = SCDynamicStoreCopyValue(store, pattern) else {
            logger.warning("[primaryIP] No IPv4 for \(primaryInterface)")
            return nil
        }
        guard let ifaceDict = unsafeBitCast(ifaceValue, to: NSDictionary.self) as? [String: Any] else {
            return nil
        }
        guard let addresses = ifaceDict["Addresses"] as? [String] else {
            logger.warning("[primaryIP] No Addresses for \(primaryInterface)")
            return nil
        }
        
        // Find first IPv4 address that's not loopback, not NAT, not link-local
        for addr in addresses {
            if addr.hasPrefix("127.") || addr.hasPrefix("169.254.") || addr.hasPrefix("192.168.64.") || addr.hasPrefix("0.") {
                continue
            }
            logger.info("[primaryIP] Found valid IP: \(addr) for \(primaryInterface)")
            return addr
        }
        
        logger.warning("[primaryIP] No valid IP found for \(primaryInterface), addresses: \(addresses)")
        return nil
    }
    
    /// Method 2: Use ifconfig (fallback)
    private static func deviceIPv4_ifconfig() -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        
        // Parse ifconfig output, find active interfaces with non-NAT IPs
        let lines = output.components(separatedBy: "\n")
        var currentInterface: String?
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // New interface section
            if !line.hasPrefix(" ") && line.contains(":") {
                currentInterface = line.components(separatedBy: ":").first
                continue
            }
            
            // Check for inet line
            if let iface = currentInterface, line.contains("inet ") {
                let parts = trimmed.components(separatedBy: " ")
                if let inetIndex = parts.firstIndex(of: "inet"), inetIndex + 1 < parts.count {
                    let ip = parts[inetIndex + 1]
                    // Skip loopback, NAT, link-local
                    if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip.hasPrefix("192.168.64.") || ip.hasPrefix("0.") {
                        continue
                    }
                    logger.info("[deviceIPv4_ifconfig] Found: \(ip) on \(iface)")
                    return ip
                }
            }
        }
        
        return nil
    }
    
    /// Method 3: Scan interfaces using getifaddrs
    private static func deviceIPv4_scanInterfaces() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }
        
        var bestIP: String?
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            let sa = ptr.pointee.ifa_addr
            guard sa != nil, sa!.pointee.sa_family == UInt8(AF_INET) else { continue }
            
            // Check if interface is up and running
            let isUp = (ptr.pointee.ifa_flags & UInt32(IFF_UP)) != 0
            let isRunning = (ptr.pointee.ifa_flags & UInt32(IFF_RUNNING)) != 0
            guard isUp && isRunning else { continue }
            
            // Get IP
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa!.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            
            // Skip loopback, NAT, link-local
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip.hasPrefix("192.168.64.") || ip.hasPrefix("0.") {
                continue
            }
            
            // Prefer Ethernet/WiFi over others
            let priority: Int
            if name.hasPrefix("en") {
                priority = 1
            } else if name.hasPrefix("bridge") {
                priority = 2
            } else {
                priority = 3
            }
            
            if bestIP == nil {
                bestIP = ip
                logger.info("[scanInterfaces] Found: \(ip) on \(name) (priority=\(priority))")
            }
        }
        
        return bestIP
    }
    
    /// Returns best available interface: Thunderbolt > Ethernet > WiFi
    static func bestAvailableInterface() -> (type: NetworkInterface.InterfaceType, bsdName: String, ipv4: String)? {
        // Use deviceIPv4Address to get the IP
        guard let ip = deviceIPv4Address() else { return nil }
        
        // Find which interface has this IP
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            let sa = ptr.pointee.ifa_addr
            guard sa != nil, sa!.pointee.sa_family == UInt8(AF_INET) else { continue }
            
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa!.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let foundIP = String(cString: hostname)
            
            if foundIP == ip {
                let type: NetworkInterface.InterfaceType
                if name.hasPrefix("en") {
                    // Distinguish WiFi (en0 on many Macs) from Ethernet
                    type = name == "en0" ? .wifi : .ethernet
                } else if name.hasPrefix("bridge") {
                    type = .thunderbolt
                } else {
                    type = .unknown
                }
                logger.info("[bestAvailableInterface] Found: \(name) type=\(type.rawValue) ip=\(ip)")
                return (type, name, ip)
            }
        }
        
        logger.warning("[bestAvailableInterface] Could not find interface for IP: \(ip)")
        return nil
    }
}
