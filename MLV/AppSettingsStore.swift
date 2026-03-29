import Foundation
import Security

@MainActor
@Observable
final class AppSettingsStore {
    static let shared = AppSettingsStore()
    
    private let keyLaunchAtLogin = "MLV_LaunchAtLogin"
    private let keyPreventSleep = "MLV_PreventSleepWhileVMRunning"
    private let keyAutoStartVMs = "MLV_AutoStartVMs"
    private let keyAPISecrets = "MLV_APISecrets"
    private static let kcService = "net.dimense.mlv"
    private static let kcUserKey = "MLV_AdminUsername"
    private static let kcPassKey = "MLV_AdminPassword"
    
    struct APISecret: Identifiable, Codable, Equatable {
        var id: String
        var placeholder: String
        var apiKey: String
    }
    
    private struct APISecretMeta: Codable {
        let id: String
        let placeholder: String
    }
    
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: keyLaunchAtLogin)
            LoginItemManager.shared.setEnabled(launchAtLogin)
        }
    }
    
    var preventSleepWhileVMRunning: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepWhileVMRunning, forKey: keyPreventSleep)
            VMManager.shared.refreshBackgroundExecution()
        }
    }
    
    var autoStartVMsOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoStartVMsOnLaunch, forKey: keyAutoStartVMs)
        }
    }
    
    var adminUsername: String {
        didSet { Self.setKeychain(Self.kcUserKey, adminUsername) }
    }
    
    var adminPassword: String {
        didSet { Self.setKeychain(Self.kcPassKey, adminPassword) }
    }
    
    var apiSecrets: [APISecret] {
        didSet {
            persistAPISecrets(oldValue: oldValue)
        }
    }
    
    private init() {
        self.launchAtLogin = UserDefaults.standard.bool(forKey: keyLaunchAtLogin)
        self.preventSleepWhileVMRunning = UserDefaults.standard.object(forKey: keyPreventSleep) as? Bool ?? true
        self.autoStartVMsOnLaunch = UserDefaults.standard.object(forKey: keyAutoStartVMs) as? Bool ?? true
        self.adminUsername = Self.getKeychain(Self.kcUserKey) ?? "mlv"
        self.adminPassword = Self.getKeychain(Self.kcPassKey) ?? "mlv"
        self.apiSecrets = []
        
        if let data = UserDefaults.standard.data(forKey: keyAPISecrets),
           let meta = try? JSONDecoder().decode([APISecretMeta].self, from: data) {
            self.apiSecrets = meta.map { item in
                APISecret(
                    id: item.id,
                    placeholder: item.placeholder,
                    apiKey: Self.getKeychain(Self.apiSecretAccount(item.id)) ?? ""
                )
            }
        }
        if self.apiSecrets.isEmpty {
            self.apiSecrets = [APISecret(id: UUID().uuidString, placeholder: "", apiKey: "")]
            persistAPISecrets(oldValue: [])
        }
    }
    
    func addAPISecretRow() {
        apiSecrets.append(APISecret(id: UUID().uuidString, placeholder: "", apiKey: ""))
    }
    
    func removeAPISecretRow(id: String) {
        apiSecrets.removeAll { $0.id == id }
        if apiSecrets.isEmpty {
            apiSecrets = [APISecret(id: UUID().uuidString, placeholder: "", apiKey: "")]
        }
    }
    
    private func persistAPISecrets(oldValue: [APISecret]) {
        let meta = apiSecrets.map { APISecretMeta(id: $0.id, placeholder: $0.placeholder) }
        if let data = try? JSONEncoder().encode(meta) {
            UserDefaults.standard.set(data, forKey: keyAPISecrets)
        }
        let oldIDs = Set(oldValue.map(\.id))
        let newIDs = Set(apiSecrets.map(\.id))
        for removedID in oldIDs.subtracting(newIDs) {
            Self.deleteKeychain(Self.apiSecretAccount(removedID))
        }
        for secret in apiSecrets {
            Self.setKeychain(Self.apiSecretAccount(secret.id), secret.apiKey)
        }
    }
    
    private static func apiSecretAccount(_ id: String) -> String {
        "MLV_ApiSecret_\(id)"
    }
    
    private static func setKeychain(_ key: String, _ value: String) {
        let data = value.data(using: .utf8) ?? Data()
        let queryAdd: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        let statusAdd = SecItemAdd(queryAdd as CFDictionary, nil)
        switch statusAdd {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let queryUpdate: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: kcService,
                kSecAttrAccount as String: key
            ]
            let attrs: [String: Any] = [kSecValueData as String: data]
            let statusUpdate = SecItemUpdate(queryUpdate as CFDictionary, attrs as CFDictionary)
            if statusUpdate == errSecSuccess {
                return
            }
            if statusUpdate == errSecItemNotFound {
                let retryStatus = SecItemAdd(queryAdd as CFDictionary, nil)
                if retryStatus == errSecSuccess {
                    return
                }
                reportKeychainError(operation: "SecItemAdd(retry)", key: key, status: retryStatus)
                return
            }
            reportKeychainError(operation: "SecItemUpdate", key: key, status: statusUpdate)
        default:
            reportKeychainError(operation: "SecItemAdd", key: key, status: statusAdd)
        }
    }
    
    private static func reportKeychainError(operation: String, key: String, status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        print("[AppSettingsStore] Keychain \(operation) failed for \(key): \(message) (\(status))")
    }
    
    private static func getKeychain(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    private static func deleteKeychain(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
