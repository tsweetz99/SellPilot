import Foundation

/// How this copy of the app is being run. The public app (every Release build) shows simple settings; debug builds keep the
/// developer fields (keys, sandbox, redirect name, token server). Debug builds can preview the public app with `--public-mode`.
enum AppMode {
    case developer, `public`
    static var current: AppMode {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--public-mode") ? .public : .developer
        #else
        return .public
        #endif
    }
}

/// Where the app finds its eBay setup, so people never type it in. The token server is built in. The Production App ID and
/// redirect name come from the server (`/api/ebay-config`): they are public values (eBay shows them in its own sign-in address)
/// and keeping them there means they can change without an app update. The last good answer is remembered on the phone.
enum EbayDeployment {
    static let defaultTokenServer = URL(string: "https://sellpilot-auth.netlify.app/api/ebay-token")!

    struct Identity: Codable, Equatable { var appID: String; var ruName: String }

    private static let cacheKey = "ebayProductionIdentity"

    /// Developers can point at another server with the saved token-server setting.
    static var tokenServer: URL { APIKeyStore.load(.ebayAuthProxy).flatMap(URL.init(string:)) ?? defaultTokenServer }

    static func configURL(for server: URL) -> URL { server.deletingLastPathComponent().appendingPathComponent("ebay-config") }

    /// What "Sign in with eBay" needs. Values a developer saved on this device win; otherwise the server's, as last fetched.
    static func productionIdentity(defaults: UserDefaults = .standard, load: (APIKeyStore.Account) -> String? = { APIKeyStore.load($0) }) -> Identity? {
        if let appID = load(.ebayAppID), let ruName = load(.ebayRuName) { return Identity(appID: appID, ruName: ruName) }
        return cached(defaults)
    }

    static func cached(_ defaults: UserDefaults = .standard) -> Identity? {
        defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) }.flatMap(valid)
    }

    /// A Production App ID contains "-PRD-"; a Sandbox one would send every seller to a sign-in page that cannot work.
    static func valid(_ identity: Identity) -> Identity? {
        let appID = identity.appID.trimmingCharacters(in: .whitespacesAndNewlines), ruName = identity.ruName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ruName.isEmpty, appID.uppercased().contains("-PRD-") else { return nil }
        return Identity(appID: appID, ruName: ruName)
    }

    /// Fetches the current values and remembers them. If the server cannot be reached or answers badly, the last good values stay.
    @discardableResult
    static func refresh(session: URLSession = .shared, server: URL = tokenServer, defaults: UserDefaults = .standard) async -> Bool {
        var request = URLRequest(url: configURL(for: server), timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let production = root["production"] as? [String: Any],
              let appID = production["appID"] as? String, let ruName = production["ruName"] as? String,
              let identity = valid(Identity(appID: appID, ruName: ruName)), let encoded = try? JSONEncoder().encode(identity) else { return false }
        defaults.set(encoded, forKey: cacheKey)
        return true
    }
}
