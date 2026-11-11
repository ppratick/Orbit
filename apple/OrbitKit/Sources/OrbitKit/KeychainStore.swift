import Foundation
#if canImport(Security)
import Security
#endif

/// Device credentials (server URL + device token). The token is the only secret a device holds.
public enum KeychainStore {
    private static let service = "orbit.device"

    public static func save(_ value: String, account: String) {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly // readable during background refresh
        SecItemAdd(add as CFDictionary, nil)
        #else
        UserDefaults.standard.set(value, forKey: "\(service).\(account)")
        #endif
    }

    public static func load(account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return UserDefaults.standard.string(forKey: "\(service).\(account)")
        #endif
    }

    public static func delete(account: String) {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        #else
        UserDefaults.standard.removeObject(forKey: "\(service).\(account)")
        #endif
    }
}
