import Foundation
import AuthenticationServices
import UIKit
import Observation

struct EbayTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var accessExpiry: Date
    var refreshExpiry: Date?
}

/// Where the seller-level access token comes from: a pasted token (testing) or a signed-in eBay connection.
protocol EbayUserTokenSource {
    func accessToken() async throws -> String
    /// Called after eBay rejects a token (401). Returns a fresh one if that is possible.
    func refreshedAccessToken() async throws -> String
}
struct StaticEbayTokenSource: EbayUserTokenSource {
    var token: String
    func accessToken() async throws -> String { token }
    func refreshedAccessToken() async throws -> String { token }
}

/// What the seller is asked to allow, and how eBay's sign-in is addressed.
struct EbayOAuthConfiguration {
    var environment: EbaySellEnvironment
    var appID: String
    /// eBay's name for the registered redirect (not a URL). It is also the redirect_uri sent when exchanging the code.
    var ruName: String
    var scopes = EbayOAuthConfiguration.defaultScopes
    /// The bounce page on the web redirects to this scheme, which the secure sign-in sheet intercepts.
    var callbackScheme = "sellpilot"
    static let defaultScopes = ["https://api.ebay.com/oauth/api_scope/sell.inventory", "https://api.ebay.com/oauth/api_scope/sell.account"]

    var authorizeBase: URL { URL(string: environment == .sandbox ? "https://auth.sandbox.ebay.com/oauth2/authorize" : "https://auth.ebay.com/oauth2/authorize")! }

    func authorizationURL(state: String) -> URL {
        var components = URLComponents(url: authorizeBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appID), URLQueryItem(name: "redirect_uri", value: ruName), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")), URLQueryItem(name: "state", value: state),
        ]
        // URLComponents leaves '+' and spaces alone in some cases; make the scope list unambiguous.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// Extracts the authorization code from the callback, checking the state value and eBay's error reports.
    func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw ServiceError.invalid(error == "access_denied" ? "eBay sign-in was cancelled." : "eBay sign-in failed (\(value("error_description") ?? error)).")
        }
        guard value("state") == expectedState else { throw ServiceError.invalid("The eBay sign-in response did not match this request. Please try again.") }
        guard let code = value("code"), !code.isEmpty else { throw ServiceError.invalid("eBay did not return a sign-in code. Please try again.") }
        return code
    }
}

// MARK: Token exchange

protocol EbayTokenExchange {
    func exchange(code: String) async throws -> EbayTokens
    func refresh(refreshToken: String) async throws -> EbayTokens
}

enum EbayTokenResponse {
    static func form(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }.joined(separator: "&").utf8)
    }

    /// A refresh grant returns only a new access token, so the existing refresh token is carried over.
    static func parse(_ data: Data, now: Date, keepingRefreshToken previous: String?) throws -> EbayTokens {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let access = json["access_token"] as? String else {
            throw ServiceError.invalid("eBay returned an unreadable sign-in response.")
        }
        guard let refresh = (json["refresh_token"] as? String) ?? previous else { throw ServiceError.invalid("eBay did not return a refresh token.") }
        func seconds(_ key: String) -> TimeInterval? { (json[key] as? Double) ?? (json[key] as? Int).map(Double.init) }
        return EbayTokens(accessToken: access, refreshToken: refresh, accessExpiry: now.addingTimeInterval(seconds("expires_in") ?? 7200),
                          refreshExpiry: seconds("refresh_token_expires_in").map { now.addingTimeInterval($0) })
    }

    static func failure(status: Int, body: Data, refreshing: Bool) -> ServiceError {
        let json = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        let error = json["error"] as? String, description = json["error_description"] as? String
        switch error {
        case "invalid_grant": return .invalid(refreshing ? "Your eBay connection has expired. Connect eBay again." : "That eBay sign-in expired or was already used. Connect eBay again.")
        case "invalid_client": return .invalid("eBay rejected the App ID / Cert ID or the redirect name (RuName). Check them in Settings.")
        default: return status >= 500 ? .invalid("eBay is temporarily unavailable.") : .invalid("eBay sign-in failed" + ((description ?? error).map { " (\($0))" } ?? " (\(status))."))
        }
    }
}

/// Exchanges codes with eBay directly. This needs the Cert ID inside the app, which is fine for your own testing
/// but not for a released app: use `ProxyEbayTokenExchange` so the secret stays on a server.
struct DirectEbayTokenExchange: EbayTokenExchange {
    var environment: EbaySellEnvironment
    var credentials: EbayCredentials
    var ruName: String
    var session: URLSession = .shared
    var now: () -> Date = Date.init

    func exchange(code: String) async throws -> EbayTokens { try await post([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", ruName)], keeping: nil, refreshing: false) }
    func refresh(refreshToken: String) async throws -> EbayTokens { try await post([("grant_type", "refresh_token"), ("refresh_token", refreshToken)], keeping: refreshToken, refreshing: true) }

    private func post(_ form: [(String, String)], keeping previous: String?, refreshing: Bool) async throws -> EbayTokens {
        var request = URLRequest(url: environment.apiBase.appending(path: "identity/v1/oauth2/token"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(credentials.appID):\(credentials.certID)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = EbayTokenResponse.form(form)
        let (data, response) = try await EbayHTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw EbayTokenResponse.failure(status: response.statusCode, body: data, refreshing: refreshing) }
        return try EbayTokenResponse.parse(data, now: now(), keepingRefreshToken: previous)
    }
}

/// Exchanges codes through your own small server, which holds the Cert ID. The server returns eBay's token response unchanged.
struct ProxyEbayTokenExchange: EbayTokenExchange {
    var endpoint: URL
    var environment: EbaySellEnvironment
    var session: URLSession = .shared
    var now: () -> Date = Date.init

    func exchange(code: String) async throws -> EbayTokens { try await post(["grant": "authorization_code", "code": code], keeping: nil, refreshing: false) }
    func refresh(refreshToken: String) async throws -> EbayTokens { try await post(["grant": "refresh_token", "refreshToken": refreshToken], keeping: refreshToken, refreshing: true) }

    private func post(_ fields: [String: String], keeping previous: String?, refreshing: Bool) async throws -> EbayTokens {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields.merging(["environment": environment.rawValue]) { current, _ in current })
        let (data, response) = try await EbayHTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw EbayTokenResponse.failure(status: response.statusCode, body: data, refreshing: refreshing) }
        return try EbayTokenResponse.parse(data, now: now(), keepingRefreshToken: previous)
    }
}

// MARK: Storage and sign-in sheet

protocol EbayTokenStorage {
    func load() -> EbayTokens?
    func save(_ tokens: EbayTokens) throws
    func clear()
}
struct KeychainEbayTokenStorage: EbayTokenStorage {
    var account: APIKeyStore.Account
    func load() -> EbayTokens? { APIKeyStore.load(account).flatMap { try? JSONDecoder().decode(EbayTokens.self, from: Data($0.utf8)) } }
    func save(_ tokens: EbayTokens) throws { try APIKeyStore.save(String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self), account) }
    func clear() { APIKeyStore.delete(account) }
}

protocol WebAuthenticator {
    /// Shows the page at `url` and returns the URL it finally redirects to (on `callbackScheme`). Throws `CancellationError` if the seller closes it.
    @MainActor func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// The system's secure sign-in sheet, so the seller's eBay password never touches SellPilot.
@MainActor final class SystemWebAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume(throwing: error ?? ServiceError.invalid("eBay sign-in did not finish.")) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: ServiceError.invalid("The eBay sign-in sheet could not be shown.")) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// MARK: Connection

/// A seller's eBay connection: signs in, stores the tokens, and hands out a valid access token, refreshing it when needed.
@MainActor @Observable final class EbayConnection: EbayUserTokenSource {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }
    private(set) var status: Status
    private var tokens: EbayTokens?
    let configuration: EbayOAuthConfiguration
    private let exchange: any EbayTokenExchange
    private let authenticator: any WebAuthenticator
    private let storage: any EbayTokenStorage
    private let now: () -> Date
    /// Tokens are renewed this long before they expire, so a request never starts with one about to lapse.
    private let renewMargin: TimeInterval = 300

    init(configuration: EbayOAuthConfiguration, exchange: any EbayTokenExchange, authenticator: any WebAuthenticator, storage: any EbayTokenStorage, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration; self.exchange = exchange; self.authenticator = authenticator; self.storage = storage; self.now = now
        let stored = storage.load()
        tokens = stored; status = stored == nil ? .disconnected : .connected
    }

    var isConnected: Bool { tokens != nil }

    func connect() async {
        guard status != .connecting else { return }
        let previous = status; status = .connecting
        do {
            let state = UUID().uuidString
            let callback = try await authenticator.authenticate(url: configuration.authorizationURL(state: state), callbackScheme: configuration.callbackScheme)
            let code = try configuration.code(from: callback, expectedState: state)
            let signedIn = try await exchange.exchange(code: code)
            try storage.save(signedIn)
            tokens = signedIn; status = .connected
        } catch is CancellationError { status = previous == .connecting ? .disconnected : previous }
        catch { status = .failed(error.localizedDescription) }
    }

    func disconnect() { storage.clear(); tokens = nil; status = .disconnected }

    func accessToken() async throws -> String {
        guard let tokens else { throw ServiceError.invalid("Connect your eBay account in Settings first.") }
        return tokens.accessExpiry.timeIntervalSince(now()) > renewMargin ? tokens.accessToken : try await refreshedAccessToken()
    }

    func refreshedAccessToken() async throws -> String {
        guard let current = tokens else { throw ServiceError.invalid("Connect your eBay account in Settings first.") }
        if let expiry = current.refreshExpiry, expiry <= now() { return try lost("Your eBay connection has expired. Connect eBay again.") }
        do {
            var renewed = try await exchange.refresh(refreshToken: current.refreshToken)
            if renewed.refreshExpiry == nil { renewed.refreshExpiry = current.refreshExpiry }
            try storage.save(renewed); tokens = renewed; status = .connected
            return renewed.accessToken
        } catch let error as ServiceError {
            // eBay says the refresh token is no good: the seller has to sign in again. Other failures (network) keep the connection.
            if error.localizedDescription.contains("expired") { return try lost(error.localizedDescription) }
            throw error
        }
    }

    private func lost(_ message: String) throws -> String {
        storage.clear(); tokens = nil; status = .failed(message)
        throw ServiceError.invalid(message)
    }
}

/// Builds a connection from the saved settings, or nil until the App ID, redirect name and a way to exchange codes are set.
@MainActor enum EbayConnections {
    static func make(_ environment: EbaySellEnvironment, authenticator: (any WebAuthenticator)? = nil) -> EbayConnection? {
        let sandbox = environment == .sandbox
        guard let appID = APIKeyStore.load(sandbox ? .ebaySandboxAppID : .ebayAppID), let ruName = APIKeyStore.load(sandbox ? .ebaySandboxRuName : .ebayRuName) else { return nil }
        let exchange: any EbayTokenExchange
        if let proxy = APIKeyStore.load(.ebayAuthProxy).flatMap(URL.init(string:)) { exchange = ProxyEbayTokenExchange(endpoint: proxy, environment: environment) }
        else if let cert = APIKeyStore.load(sandbox ? .ebaySandboxCertID : .ebayCertID) { exchange = DirectEbayTokenExchange(environment: environment, credentials: .init(appID: appID, certID: cert), ruName: ruName) }
        else { return nil }
        return EbayConnection(configuration: .init(environment: environment, appID: appID, ruName: ruName), exchange: exchange, authenticator: authenticator ?? SystemWebAuthenticator(),
                              storage: KeychainEbayTokenStorage(account: sandbox ? .ebaySandboxOAuthTokens : .ebayOAuthTokens))
    }
}
