import Foundation

enum VMError: Error, LocalizedError {
    case virtualizationNotSupported
    case configurationInvalid(String)
    
    var errorDescription: String? {
        switch self {
        case .virtualizationNotSupported:
            return "Virtualization is not supported on this Mac"
        case .configurationInvalid(let reason):
            return "Invalid VM configuration: \(reason)"
        }
    }
}
