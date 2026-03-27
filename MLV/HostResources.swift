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
        
        // Strategy: Detect real active interfaces first
        let bsdNames = ["en0", "en1", "en2", "en3", "en4", "bridge0"]
        
        for bsd in bsdNames {
            if let ip = getIPAddress(for: bsd), !ip.isEmpty {
                // Determine type based on common macOS naming conventions
                var type: NetworkInterface.InterfaceType = .unknown
                var name = "Interface \(bsd)"
                var speed = "Unknown"
                
                if bsd == "en0" {
                    type = .wifi
                    name = "Wi-Fi"
                    speed = "2.4 Gbps"
                } else if bsd.hasPrefix("en") {
                    type = .ethernet
                    name = "Ethernet (\(bsd))"
                    speed = "10 Gbps"
                } else if bsd.hasPrefix("bridge") {
                    type = .thunderbolt
                    name = "Thunderbolt Bridge"
                    speed = "40 Gbps"
                }
                
                interfaces.append(NetworkInterface(name: name, type: type, speed: speed, bsdName: bsd, isActive: true))
            }
        }
        
        // Fallback if nothing is active
        if interfaces.isEmpty {
            interfaces.append(NetworkInterface(name: "Virtual NAT", type: .unknown, speed: "1 Gbps", bsdName: "nat0", isActive: true))
        }
        
        return interfaces
    }

    static func ipAddress(for bsdName: String) -> String? {
        getIPAddress(for: bsdName)
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
