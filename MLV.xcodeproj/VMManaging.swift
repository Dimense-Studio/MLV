import Foundation

@MainActor
protocol VMManaging: AnyObject {
    var virtualMachines: [VirtualMachine] { get }
}

extension VMManager: VMManaging {}
