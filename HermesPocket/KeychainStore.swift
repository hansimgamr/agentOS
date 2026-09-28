import Foundation
import Security

enum KeychainStore {
    private static let service = "com.agentos.app"
    private static let deviceAccount = "device-access-key"
    private static let legacyAccount = "api-server-key"

    static func read() -> String? { read(account: deviceAccount) }
    static func readLegacy() -> String? { read(account: legacyAccount) }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool { save(value, account: deviceAccount) }
    @discardableResult
    static func saveLegacy(_ value: String) -> Bool { save(value, account: legacyAccount) }

    static func deleteLegacy() {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: legacyAccount]
        SecItemDelete(key as CFDictionary)
    }

    private static func save(_ value: String, account: String) -> Bool {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        if value.isEmpty { return SecItemDelete(key as CFDictionary) == errSecSuccess || read(account: account) == nil }
        let bytes = Data(value.utf8)
        let updates: [String: Any] = [kSecValueData as String: bytes,
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(key as CFDictionary, updates as CFDictionary) == errSecSuccess { return true }
        var item = key
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
