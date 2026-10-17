import Foundation
import Security

/// Keychain storage for third-party API credentials. Prototype only: credentials on the device can be extracted,
/// so a shipping build should call your own server, which holds them and enforces per-user limits.
enum APIKeyStore {
    enum Account: String {
        case anthropic = "api-key", ebayAppID = "ebay-app-id", ebayCertID = "ebay-cert-id"
        case ebaySandboxAppID = "ebay-sandbox-app-id", ebaySandboxCertID = "ebay-sandbox-cert-id", ebaySandboxUserToken = "ebay-sandbox-user-token"
        case ebaySandboxRuName = "ebay-sandbox-runame", ebayRuName = "ebay-runame", ebayAuthProxy = "ebay-auth-proxy"
        case ebaySandboxOAuthTokens = "ebay-sandbox-oauth-tokens", ebayOAuthTokens = "ebay-oauth-tokens", installKey = "install-key"
        /// Debug builds also read these environment variables (set them in the Xcode scheme).
        var environmentName: String {
            switch self { case .anthropic: "SELLPILOT_ANTHROPIC_API_KEY"; case .ebayAppID: "SELLPILOT_EBAY_APP_ID"; case .ebayCertID: "SELLPILOT_EBAY_CERT_ID"
            case .ebaySandboxAppID: "SELLPILOT_EBAY_SANDBOX_APP_ID"; case .ebaySandboxCertID: "SELLPILOT_EBAY_SANDBOX_CERT_ID"; case .ebaySandboxUserToken: "SELLPILOT_EBAY_SANDBOX_USER_TOKEN"
            case .ebaySandboxRuName: "SELLPILOT_EBAY_SANDBOX_RUNAME"; case .ebayRuName: "SELLPILOT_EBAY_RUNAME"; case .ebayAuthProxy: "SELLPILOT_EBAY_AUTH_PROXY"
            case .ebaySandboxOAuthTokens: "SELLPILOT_EBAY_SANDBOX_OAUTH_TOKENS"; case .ebayOAuthTokens: "SELLPILOT_EBAY_OAUTH_TOKENS"; case .installKey: "SELLPILOT_INSTALL_KEY" }
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

    private static let installKeyLock = NSLock()
    private static var cachedInstallKey: String?

    /// A random identifier for this install, created on first use and kept in the Keychain. The token server uses it to
    /// rate-limit installs separately. It identifies nothing about the person. It is also remembered in memory, so it stays
    /// the same for the life of the app even if the Keychain refuses to store it (which would otherwise make every request
    /// look like a brand-new install).
    static func installKey() -> String {
        installKeyLock.lock(); defer { installKeyLock.unlock() }
        if let cachedInstallKey { return cachedInstallKey }
        if let existing = load(.installKey), existing.count >= 32 { cachedInstallKey = existing; return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let key = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess ? bytes.map { String(format: "%02x", $0) }.joined() : (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        try? save(key, .installKey)
        cachedInstallKey = key
        return key
    }
}
