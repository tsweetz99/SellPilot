import XCTest
@testable import SellPilot

private final class OAuthStub: URLProtocol {
    static var handler: ((URLRequest, Data) -> (Int, Data))?
    static var log: [(request: URLRequest, body: Data)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 8192); body = Data()
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        Self.log.append((request, body))
        let (status, data) = Self.handler!(request, body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakeExchange: EbayTokenExchange {
    var exchangeCalls: [String] = [], refreshCalls: [String] = []
    var nextTokens = EbayTokens(accessToken: "access-1", refreshToken: "refresh-1", accessExpiry: Date().addingTimeInterval(7200), refreshExpiry: Date().addingTimeInterval(86_400 * 300))
    var refreshResult: Result<EbayTokens, ServiceError> = .success(EbayTokens(accessToken: "access-2", refreshToken: "refresh-1", accessExpiry: Date().addingTimeInterval(7200), refreshExpiry: nil))
    func exchange(code: String) async throws -> EbayTokens { exchangeCalls.append(code); return nextTokens }
    func refresh(refreshToken: String) async throws -> EbayTokens { refreshCalls.append(refreshToken); return try refreshResult.get() }
}
private final class MemoryStorage: EbayTokenStorage {
    var stored: EbayTokens?
    func load() -> EbayTokens? { stored }
    func save(_ tokens: EbayTokens) throws { stored = tokens }
    func clear() { stored = nil }
}
/// Plays the part of the secure sign-in sheet: returns eBay's redirect, echoing the state it was given.
@MainActor private final class FakeSheet: WebAuthenticator {
    var behavior: (URL) throws -> URL = { url in
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: "sellpilot://ebay/callback?code=AUTHCODE&state=\(state)")!
    }
    var shown: [URL] = []
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { shown.append(url); return try behavior(url) }
}

final class EbayOAuthTests: XCTestCase {
    override func setUp() { OAuthStub.log = []; OAuthStub.handler = nil }

    private let configuration = EbayOAuthConfiguration(environment: .sandbox, appID: "App-SBX-1", ruName: "Name-App-SBX-xyz")
    private func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [OAuthStub.self]; return URLSession(configuration: c) }
    private func tokenReply(refresh: String? = "refresh-token") -> Data {
        var body: [String: Any] = ["access_token": "access-token", "expires_in": 7200, "token_type": "User Access Token"]
        if let refresh { body["refresh_token"] = refresh; body["refresh_token_expires_in"] = 47_304_000 }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    // MARK: URLs

    func testAuthorizationURLCarriesTheAppRedirectNameScopesAndState() throws {
        let url = configuration.authorizationURL(state: "S1")
        XCTAssertEqual(url.host, "auth.sandbox.ebay.com"); XCTAssertEqual(url.path, "/oauth2/authorize")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), "App-SBX-1"); XCTAssertEqual(value("redirect_uri"), "Name-App-SBX-xyz"); XCTAssertEqual(value("response_type"), "code"); XCTAssertEqual(value("state"), "S1")
        XCTAssertEqual(value("scope"), "https://api.ebay.com/oauth/api_scope/sell.inventory https://api.ebay.com/oauth/api_scope/sell.account")
        XCTAssertEqual(EbayOAuthConfiguration(environment: .production, appID: "a", ruName: "r").authorizationURL(state: "x").host, "auth.ebay.com")
    }

    func testCallbackParsing() throws {
        XCTAssertEqual(try configuration.code(from: URL(string: "sellpilot://ebay/callback?code=v%5E1.1%23abc&state=S1&expires_in=299")!, expectedState: "S1"), "v^1.1#abc", "the code is decoded once")
        func message(_ url: String) -> String { do { _ = try configuration.code(from: URL(string: url)!, expectedState: "S1"); return "no error" } catch { return error.localizedDescription } }
        XCTAssertTrue(message("sellpilot://ebay/callback?code=c&state=OTHER").contains("did not match"))
        XCTAssertTrue(message("sellpilot://ebay/callback?error=access_denied&state=S1").contains("cancelled"))
        XCTAssertTrue(message("sellpilot://ebay/callback?state=S1").contains("did not return"))
        XCTAssertTrue(message("sellpilot://ebay/callback?error=invalid_scope&error_description=bad%20scope&state=S1").contains("bad scope"))
    }

    // MARK: Exchange

    func testDirectExchangeSendsEbaysFormAndParsesTokens() async throws {
        OAuthStub.handler = { _, _ in (200, self.tokenReply()) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let exchange = DirectEbayTokenExchange(environment: .sandbox, credentials: .init(appID: "app", certID: "cert"), ruName: "Name-App-SBX-xyz", session: session(), now: { now })
        let tokens = try await exchange.exchange(code: "v^1.1#abc&x")
        let sent = try XCTUnwrap(OAuthStub.log.first)
        XCTAssertEqual(sent.request.url?.host, "api.sandbox.ebay.com"); XCTAssertEqual(sent.request.url?.path, "/identity/v1/oauth2/token")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("app:cert".utf8).base64EncodedString())
        XCTAssertEqual(String(decoding: sent.body, as: UTF8.self), "grant_type=authorization_code&code=v%5E1.1%23abc%26x&redirect_uri=Name-App-SBX-xyz", "special characters in the code are percent-encoded")
        XCTAssertEqual(tokens, EbayTokens(accessToken: "access-token", refreshToken: "refresh-token", accessExpiry: now.addingTimeInterval(7200), refreshExpiry: now.addingTimeInterval(47_304_000)))
    }

    func testRefreshKeepsTheExistingRefreshTokenBecauseEbayDoesNotReturnANewOne() async throws {
        OAuthStub.handler = { _, _ in (200, self.tokenReply(refresh: nil)) }
        let tokens = try await DirectEbayTokenExchange(environment: .sandbox, credentials: .init(appID: "a", certID: "c"), ruName: "r", session: session()).refresh(refreshToken: "old-refresh")
        XCTAssertEqual(tokens.refreshToken, "old-refresh"); XCTAssertEqual(tokens.accessToken, "access-token")
        XCTAssertEqual(String(decoding: OAuthStub.log[0].body, as: UTF8.self), "grant_type=refresh_token&refresh_token=old-refresh")
    }

    func testExchangeFailuresExplainWhatToDo() async throws {
        OAuthStub.handler = { _, _ in (400, Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8)) }
        let direct = DirectEbayTokenExchange(environment: .sandbox, credentials: .init(appID: "a", certID: "c"), ruName: "r", session: session())
        do { _ = try await direct.exchange(code: "x"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("already used")) }
        do { _ = try await direct.refresh(refreshToken: "x"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("has expired")) }
        OAuthStub.handler = { _, _ in (401, Data(#"{"error":"invalid_client"}"#.utf8)) }
        do { _ = try await direct.exchange(code: "x"); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("RuName")) }
    }

    func testProxyExchangeSendsJSONAndNeverTheCertID() async throws {
        OAuthStub.handler = { _, _ in (200, self.tokenReply()) }
        let proxy = ProxyEbayTokenExchange(endpoint: URL(string: "https://auth.example.com/.netlify/functions/ebay-token")!, environment: .sandbox, session: session())
        _ = try await proxy.exchange(code: "CODE")
        _ = try await proxy.refresh(refreshToken: "RT")
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: OAuthStub.log[0].body) as? [String: String])
        XCTAssertEqual(first, ["grant": "authorization_code", "code": "CODE", "environment": "sandbox"])
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: OAuthStub.log[1].body) as? [String: String])
        XCTAssertEqual(second, ["grant": "refresh_token", "refreshToken": "RT", "environment": "sandbox"])
        XCTAssertNil(OAuthStub.log[0].request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: Connection

    @MainActor private func connection(exchange: FakeExchange? = nil, sheet: FakeSheet? = nil, storage: MemoryStorage? = nil, now: @escaping () -> Date = Date.init) -> EbayConnection {
        EbayConnection(configuration: configuration, exchange: exchange ?? FakeExchange(), authenticator: sheet ?? FakeSheet(), storage: storage ?? MemoryStorage(), now: now)
    }

    @MainActor func testConnectSignsInStoresTokensAndPassesTheCode() async throws {
        let exchange = FakeExchange(), storage = MemoryStorage(), sheet = FakeSheet()
        let conn = connection(exchange: exchange, sheet: sheet, storage: storage)
        XCTAssertEqual(conn.status, .disconnected)
        await conn.connect()
        XCTAssertEqual(conn.status, .connected); XCTAssertEqual(exchange.exchangeCalls, ["AUTHCODE"]); XCTAssertEqual(storage.stored?.accessToken, "access-1")
        XCTAssertEqual(sheet.shown.first?.host, "auth.sandbox.ebay.com")
        let token = try await conn.accessToken()
        XCTAssertEqual(token, "access-1"); XCTAssertTrue(exchange.refreshCalls.isEmpty, "a fresh token is reused")
        XCTAssertEqual(connection(storage: storage).status, .connected, "the connection survives a relaunch")
    }

    @MainActor func testAMismatchedStateOrCancelledSheetStoresNothing() async throws {
        let sheet = FakeSheet(), exchange = FakeExchange(), storage = MemoryStorage()
        sheet.behavior = { _ in URL(string: "sellpilot://ebay/callback?code=EVIL&state=forged")! }
        let conn = connection(exchange: exchange, sheet: sheet, storage: storage)
        await conn.connect()
        if case .failed(let reason) = conn.status { XCTAssertTrue(reason.contains("did not match")) } else { XCTFail("expected a failure") }
        XCTAssertTrue(exchange.exchangeCalls.isEmpty, "a forged callback never reaches the token exchange"); XCTAssertNil(storage.stored)
        sheet.behavior = { _ in throw CancellationError() }
        await conn.connect()
        if case .failed = conn.status {} else { XCTFail("a cancelled retry keeps the earlier failure state, not a new error") }
        let fresh = connection(exchange: exchange, sheet: sheet, storage: storage); await fresh.connect()
        XCTAssertEqual(fresh.status, .disconnected, "cancelling from a clean state leaves it disconnected")
    }

    @MainActor func testAccessTokensAreRenewedBeforeTheyExpireAndTheRenewalIsStored() async throws {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let exchange = FakeExchange(), storage = MemoryStorage()
        exchange.nextTokens = EbayTokens(accessToken: "access-1", refreshToken: "refresh-1", accessExpiry: clock.addingTimeInterval(7200), refreshExpiry: clock.addingTimeInterval(86_400))
        let conn = connection(exchange: exchange, storage: storage, now: { clock })
        await conn.connect()
        clock = clock.addingTimeInterval(7200 - 600)
        let early = try await conn.accessToken(); XCTAssertEqual(early, "access-1", "still outside the five-minute renewal margin")
        clock = clock.addingTimeInterval(400)
        let renewed = try await conn.accessToken()
        XCTAssertEqual(renewed, "access-2"); XCTAssertEqual(exchange.refreshCalls, ["refresh-1"]); XCTAssertEqual(storage.stored?.accessToken, "access-2")
        XCTAssertEqual(storage.stored?.refreshExpiry, exchange.nextTokens.refreshExpiry, "the refresh expiry is carried over when a renewal does not report one")
    }

    @MainActor func testALapsedRefreshTokenSignsTheSellerOutButANetworkErrorDoesNot() async throws {
        let exchange = FakeExchange(), storage = MemoryStorage()
        let conn = connection(exchange: exchange, storage: storage); await conn.connect()
        exchange.refreshResult = .failure(.invalid("No internet connection."))
        do { _ = try await conn.refreshedAccessToken(); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "No internet connection.") }
        XCTAssertEqual(conn.status, .connected); XCTAssertNotNil(storage.stored, "a network failure keeps the connection")
        exchange.refreshResult = .failure(.invalid("Your eBay connection has expired. Connect eBay again."))
        do { _ = try await conn.refreshedAccessToken(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Connect eBay again")); XCTAssertTrue(error is EbayAuthError, "the UI offers to open Settings") }
        XCTAssertNil(storage.stored); XCTAssertFalse(conn.isConnected)
        if case .failed = conn.status {} else { XCTFail("expected failed status") }
        do { _ = try await conn.accessToken(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Connect your eBay account")); XCTAssertTrue(error is EbayAuthError) }
    }

    @MainActor func testDisconnectForgetsTheTokens() async throws {
        let storage = MemoryStorage(); let conn = connection(storage: storage)
        await conn.connect(); conn.disconnect()
        XCTAssertEqual(conn.status, .disconnected); XCTAssertNil(storage.stored)
    }
}
