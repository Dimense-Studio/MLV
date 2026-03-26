import Foundation
import AppKit

struct HostResources {
    static var cpuCount: Int {
        ProcessInfo.processInfo.processorCount
    }
    
    static var totalMemoryGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }
    
    static var freeDiskSpaceGB: Int {
        let path = NSHomeDirectory()
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            if let freeSize = systemAttributes[.systemFreeSize] as? NSNumber {
                return Int(freeSize.int64Value / (1024 * 1024 * 1024))
            }
        } catch {
            print("Error getting free disk space: \(error)")
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
        var interfaces: [NetworkInterface] = []
        
        // Use SCNetworkInterface to get real system interfaces if available
        // Fallback to common Mac mini M4 defaults
        let defaultInterfaces = [
            ("10Gb Ethernet", HostResources.NetworkInterface.InterfaceType.ethernet, "10 Gbps", "en1"),
            ("Wi-Fi 6E", HostResources.NetworkInterface.InterfaceType.wifi, "2.4 Gbps", "en0"),
            ("Thunderbolt Bridge", HostResources.NetworkInterface.InterfaceType.thunderbolt, "40 Gbps", "bridge0")
        ]
        
        for (name, type, speed, bsd) in defaultInterfaces {
            var interface = NetworkInterface(name: name, type: type, speed: speed, bsdName: bsd)
            if let ip = getIPAddress(for: bsd), !ip.isEmpty {
                interface.isActive = true
            }
            interfaces.append(interface)
        }
        
        // Scan for any other active 'en' interfaces that might be the real WiFi/Ethernet
        for i in 0...4 {
            let bsd = "en\(i)"
            if !interfaces.contains(where: { $0.bsdName == bsd }), let ip = getIPAddress(for: bsd), !ip.isEmpty {
                interfaces.append(NetworkInterface(name: "Other Interface (\(bsd))", type: .unknown, speed: "Unknown", bsdName: bsd, isActive: true))
            }
        }
        
        return interfaces
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
