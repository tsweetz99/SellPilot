import Foundation
import Security

/// Keychain storage for the identification API key. Prototype only: a key on the device can be extracted,
/// so a shipping build should call your own server, which holds the key and enforces per-user limits.
enum APIKeyStore {
    private static let service = "com.sellpilot.anthropic"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["SELLPILOT_ANTHROPIC_API_KEY"], !key.isEmpty { return key }
        #endif
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        SecItemDelete(query as CFDictionary)
        var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServiceError.invalid("Could not save the key to the Keychain (error \(status)).") }
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
