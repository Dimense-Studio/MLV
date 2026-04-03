import Foundation
import Virtualization

final class VMRuntimeDelegate: NSObject, VZVirtualMachineDelegate {
    private weak var vm: VirtualMachine?

    init(vm: VirtualMachine) {
        self.vm = vm
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard let vm else { return }
            vm.addLog("VM guest stopped.")
            vm.state = .stopped
            if vm.isInstalled {
                vm.addLog("System rebooting into OS mode...")
                if vm.pendingAutoStartAfterInstall {
                    vm.stage = .rebooting
                    vm.pendingAutoStartAfterInstall = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        try? await VMManager.shared.startVM(vm)
                    }
                } else if !vm.userInitiatedStop {
                    vm.stage = .crashed
                    AppNotifications.shared.notify(title: "VM Stopped", body: "\(vm.name) stopped unexpectedly")
                } else {
                    vm.stage = .installed
                }
            } else {
                vm.stage = .stopped
            }
            vm.userInitiatedStop = false
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        Task { @MainActor in
            guard let vm else { return }
            vm.addLog("VM stopped with error: \((error as NSError).localizedDescription)", isError: true)
            vm.state = .error((error as NSError).localizedDescription)
            vm.stage = .error
            AppNotifications.shared.notify(title: "VM Error", body: "\(vm.name): \((error as NSError).localizedDescription)")
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: any Error) {
        Task { @MainActor in
            guard let vm else { return }
            vm.addLog("Network attachment disconnected: \((error as NSError).localizedDescription)", isError: true)
        }
    }
}
