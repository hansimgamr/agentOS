import Foundation
import Security

enum KeychainStore {
    private static let service = "com.agentos.app"
    private static let profileAccount = "connection-profile-v2"
    private static let deviceAccount = "device-access-key"
    private static let legacyAccount = "api-server-key"

    static func read() -> String? { read(account: deviceAccount) }
    static func readLegacy() -> String? { read(account: legacyAccount) }

    static func readProfile() -> HermesConnectionProfile? {
        guard let data = readData(account: profileAccount) else { return nil }
        return try? JSONDecoder().decode(HermesConnectionProfile.self, from: data)
    }

    @discardableResult
    static func saveProfile(_ profile: HermesConnectionProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        return save(data, account: profileAccount)
    }

    static func deleteProfile() { delete(account: profileAccount) }

    private static func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readData(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func save(_ value: String) -> Bool { save(value, account: deviceAccount) }
    @discardableResult
    static func saveLegacy(_ value: String) -> Bool { save(value, account: legacyAccount) }

    static func deleteLegacy() {
        delete(account: legacyAccount)
    }

    static func deleteDeviceKey() { delete(account: deviceAccount) }

    private static func save(_ value: String, account: String) -> Bool {
        if value.isEmpty { delete(account: account); return true }
        return save(Data(value.utf8), account: account)
    }

    private static func save(_ bytes: Data, account: String) -> Bool {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        let updates: [String: Any] = [kSecValueData as String: bytes,
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        if SecItemUpdate(key as CFDictionary, updates as CFDictionary) == errSecSuccess { return true }
        var item = key
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(account: String) {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        SecItemDelete(key as CFDictionary)
    }
}

struct HermesConnectionProfile: Codable, Equatable {
    let endpoint: String
    let fingerprint: String
    let token: String
    let deviceID: String?
}
