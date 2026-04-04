import Foundation

@Observable
final class VMNetworkService {
    static let shared = VMNetworkService()
    
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
        if let preferred, !preferred.isEmpty { return preferred }
        let interfaces = HostResources.getNetworkInterfaces()
        return interfaces.first(where: { $0.bsdName == "en0" })?.bsdName ?? interfaces.first?.bsdName
    }
}
