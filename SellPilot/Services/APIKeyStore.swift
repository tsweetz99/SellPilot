import Foundation
import Security

/// Keychain storage for third-party API credentials. Prototype only: credentials on the device can be extracted,
/// so a shipping build should call your own server, which holds them and enforces per-user limits.
enum APIKeyStore {
    enum Account: String {
        case anthropic = "api-key", ebayAppID = "ebay-app-id", ebayCertID = "ebay-cert-id"
        case ebaySandboxAppID = "ebay-sandbox-app-id", ebaySandboxCertID = "ebay-sandbox-cert-id", ebaySandboxUserToken = "ebay-sandbox-user-token"
        /// Debug builds also read these environment variables (set them in the Xcode scheme).
        var environmentName: String {
            switch self { case .anthropic: "SELLPILOT_ANTHROPIC_API_KEY"; case .ebayAppID: "SELLPILOT_EBAY_APP_ID"; case .ebayCertID: "SELLPILOT_EBAY_CERT_ID"
            case .ebaySandboxAppID: "SELLPILOT_EBAY_SANDBOX_APP_ID"; case .ebaySandboxCertID: "SELLPILOT_EBAY_SANDBOX_CERT_ID"; case .ebaySandboxUserToken: "SELLPILOT_EBAY_SANDBOX_USER_TOKEN" }
        }
    }

    private static let service = "com.sellpilot.anthropic"

    private static func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.rawValue]
    }

    static func load(_ account: Account = .anthropic) -> String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment[account.environmentName], !value.isEmpty { return value }
        #endif
        var request = query(account); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, _ account: Account = .anthropic) throws {
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account); item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ServiceError.invalid("Could not save to the Keychain (error \(status)).") }
    }

    static func delete(_ account: Account = .anthropic) { SecItemDelete(query(account) as CFDictionary) }
}
