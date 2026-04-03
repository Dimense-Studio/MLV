import Foundation
import Security

enum EntitlementChecker {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func hasEntitlement(_ key: String) -> Bool {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        let result: Bool
        if let boolValue = value as? Bool {
            result = boolValue
        } else if let numberValue = value as? NSNumber {
            result = numberValue.boolValue
        } else {
            result = false
        }

        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }
}
