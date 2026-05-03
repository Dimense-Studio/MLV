import Foundation
import SwiftUI

struct PairingRequest: Identifiable, Equatable {
    let id: String
    let nodeName: String
}

@MainActor
final class ClusterDiscovery {
    static let shared = ClusterDiscovery()

    var pendingPairRequests: [PairingRequest] = []

    private init() {}

    func acceptPairing(_ request: PairingRequest) async throws {
        pendingPairRequests.removeAll { $0.id == request.id }
        NotificationCenter.default.post(name: .nodeStatusChanged, object: request.id)
    }

    func rejectPairing(_ request: PairingRequest) async throws {
        pendingPairRequests.removeAll { $0.id == request.id }
    }
}

@MainActor
final class ClusterController {
    static let shared = ClusterController()

    private(set) var currentRole: ClusterRole?

    private init() {}

    func start(with role: ClusterRole) {
        currentRole = role
    }
}
