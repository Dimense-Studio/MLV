import Foundation

struct VMListSnapshot {
    let all: [VirtualMachine]
    let filtered: [VirtualMachine]
    let runningCount: Int
    let averageCPUUsage: Int
    let averageMemoryUsage: Int
    let allOperational: Bool
}

@MainActor
final class VMListViewModel {
    private weak var vmManager: VMManaging?

    init(vmManager: VMManaging) {
        self.vmManager = vmManager
    }

    convenience init() {
        self.init(vmManager: VMManager.shared)
    }

    func snapshot(search: String, isContainerMode: Bool) -> VMListSnapshot {
        let all = (vmManager?.virtualMachines ?? []).filter { $0.isContainerWorkload == isContainerMode }
        let filtered = all.filter { search.isEmpty ? true : $0.name.localizedCaseInsensitiveContains(search) }
        let runningCount = all.filter(\.state.isRunning).count
        let runningVMs = filtered.filter(\.state.isRunning)
        let sampledCPU = runningVMs.map { vm in
            vm.state.isRunning ? (vm.hasGuestUsageSample ? vm.guestCPUUsagePercent : -1) : 0
        }.filter { $0 >= 0 }
        let sampledMemory = runningVMs.map { vm in
            vm.state.isRunning ? (vm.hasGuestUsageSample ? vm.guestMemoryUsagePercent : -1) : 0
        }.filter { $0 >= 0 }
        let averageCPUUsage = sampledCPU.isEmpty ? 0 : sampledCPU.reduce(0, +) / sampledCPU.count
        let averageMemoryUsage = sampledMemory.isEmpty ? 0 : sampledMemory.reduce(0, +) / sampledMemory.count
        let allOperational = !all.isEmpty && runningCount == all.count

        return VMListSnapshot(
            all: all,
            filtered: filtered,
            runningCount: runningCount,
            averageCPUUsage: averageCPUUsage,
            averageMemoryUsage: averageMemoryUsage,
            allOperational: allOperational
        )
    }
}
