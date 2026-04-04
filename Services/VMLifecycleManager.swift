import Foundation
import Virtualization

/// Manages the lifecycle of virtual machines with serialized execution.
/// Prevents concurrent start/stop/restart operations on the same VM instance.
actor VMLifecycleManager {
    static let shared = VMLifecycleManager()
    
    private var activeTasks: [UUID: Task<Void, Error>] = [:]
    
    private init() {}
    
    func performOperation(for vmID: UUID, operation: @escaping () async throws -> Void) async throws {
        // Cancel any existing task for this VM if necessary, or wait for it.
        // For lifecycle, we usually want to wait or throw an error if already in progress.
        if let existingTask = activeTasks[vmID] {
            _ = try await existingTask.value
        }
        
        let task = Task {
            try await operation()
        }
        
        activeTasks[vmID] = task
        
        do {
            try await task.value
            activeTasks.removeValue(forKey: vmID)
        } catch {
            activeTasks.removeValue(forKey: vmID)
            throw error
        }
    }
    
    func isOperationInProgress(for vmID: UUID) -> Bool {
        return activeTasks[vmID] != nil
    }
}
