import XCTest
@testable import SellPilot

private final class TokenStub: URLProtocol {
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

private struct FixedTokens: EbayAppTokenSource {
    var result: Result<String, ServiceError>
    var calls: Counter
    func accessToken(forceRefresh: Bool) async throws -> String { calls.count += 1; return try result.get() }
}
private final class Counter { var count = 0 }

final class AppTokenTests: XCTestCase {
    override func setUp() { TokenStub.log = []; TokenStub.handler = nil }

    private let endpoint = URL(string: "https://auth.example.com/api/ebay-token")!
    private let key = String(repeating: "ab", count: 32)
    private func session() -> URLSession { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [TokenStub.self]; return URLSession(configuration: c) }
    private func ok(_ token: String = "app-token", expires: Int = 7200) -> Data { try! JSONSerialization.data(withJSONObject: ["access_token": token, "expires_in": expires, "token_type": "Application Access Token"]) }

    func testProxyAppTokensSendTheInstallKeyAndAreCached() async throws {
        TokenStub.handler = { _, _ in (200, self.ok()) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let provider = ProxyAppTokenProvider(endpoint: endpoint, environment: .production, installKey: key, session: session(), now: { clock })
        let first = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(first, "app-token")
        let sent = try XCTUnwrap(TokenStub.log.first)
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-SellPilot-Install"), key); XCTAssertNil(sent.request.value(forHTTPHeaderField: "Authorization"), "no secret is sent")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? [String: String], ["environment": "production", "grant": "client_credentials"])
        _ = try await provider.accessToken(forceRefresh: false); XCTAssertEqual(TokenStub.log.count, 1, "cached")
        _ = try await provider.accessToken(forceRefresh: true); XCTAssertEqual(TokenStub.log.count, 2, "forced refresh asks again")
        clock = clock.addingTimeInterval(7200); _ = try await provider.accessToken(forceRefresh: false); XCTAssertEqual(TokenStub.log.count, 3, "expired tokens are fetched again")
    }

    func testProxyFailuresExplainWhatIsWrong() async throws {
        func message(_ status: Int, _ error: String?) async -> String {
            TokenStub.handler = { _, _ in (status, error.map { Data(#"{"error":"\#($0)"}"#.utf8) } ?? Data()) }
            do { _ = try await ProxyAppTokenProvider(endpoint: self.endpoint, environment: .sandbox, installKey: self.key, session: self.session()).accessToken(forceRefresh: true); return "no error" }
            catch { return error.localizedDescription }
        }
        let limited = await message(429, "rate_limited"), notEnabled = await message(403, "forbidden"), keyBad = await message(401, "install_key_required")
        let down = await message(503, "limiter_unavailable"), missing = await message(404, nil)
        XCTAssertTrue(limited.contains("Too many")); XCTAssertTrue(notEnabled.contains("isn't set up")); XCTAssertTrue(keyBad.contains("install key"))
        XCTAssertTrue(down.contains("temporarily")); XCTAssertTrue(missing.contains("address looks wrong"))
    }

    func testFallbackUsesTheDeviceOnlyWhenTheServerFails() async throws {
        let serverCalls = Counter(), deviceCalls = Counter()
        let good = FallbackAppTokenSource(primary: FixedTokens(result: .success("from-server"), calls: serverCalls), fallback: FixedTokens(result: .success("from-device"), calls: deviceCalls))
        let a = try await good.accessToken(forceRefresh: false); XCTAssertEqual(a, "from-server"); XCTAssertEqual(deviceCalls.count, 0)
        let broken = FallbackAppTokenSource(primary: FixedTokens(result: .failure(.invalid("down")), calls: serverCalls), fallback: FixedTokens(result: .success("from-device"), calls: deviceCalls))
        let b = try await broken.accessToken(forceRefresh: false); XCTAssertEqual(b, "from-device")
        let alone = FallbackAppTokenSource(primary: FixedTokens(result: .failure(.invalid("down")), calls: serverCalls), fallback: nil)
        do { _ = try await alone.accessToken(forceRefresh: false); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "down") }
    }

    func testServicesUseInjectedAppTokensWithoutAnyCertID() async throws {
        TokenStub.handler = { request, _ in
            if request.url!.path.contains("get_category_suggestions") { return (200, try! JSONSerialization.data(withJSONObject: ["categorySuggestions": [["category": ["categoryId": "1", "categoryName": "Books"]]]])) }
            if request.url!.path.contains("item_summary/search") { return (200, try! JSONSerialization.data(withJSONObject: ["itemSummaries": [["title": "A", "price": ["value": "5.00", "currency": "USD"]]]])) }
            return (404, Data())
        }
        let tokens = FixedTokens(result: .success("server-minted"), calls: Counter())
        let sell = EbaySellService(configuration: .init(environment: .sandbox, credentials: nil, tokens: StaticEbayTokenSource(token: "seller")), session: session(), appTokens: tokens)
        let categories = try await sell.suggestCategories(query: "book")
        XCTAssertEqual(categories.first?.id, "1")
        XCTAssertEqual(TokenStub.log.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer server-minted")
        let research = EbayBrowseMarketResearchService(configuration: .init(credentials: nil), session: session(), appTokens: tokens)
        var item = SellItem(); item.title = "A book"
        _ = try await research.research(item: item)
        XCTAssertEqual(TokenStub.log.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer server-minted")
        XCTAssertFalse(TokenStub.log.contains { $0.request.url!.path.contains("oauth2/token") }, "nothing tried to use a Cert ID")
        let none = EbayBrowseMarketResearchService(configuration: .init(credentials: nil), session: session())
        do { _ = try await none.research(item: item); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("isn't set up")) }
    }

    func testInstallKeyIsRandomHexAndStable() {
        let first = APIKeyStore.installKey(), second = APIKeyStore.installKey()
        XCTAssertEqual(first, second, "created once, then reused")
        XCTAssertTrue(first.range(of: "^[0-9a-f]{32,64}$", options: .regularExpression) != nil, "matches what the server accepts")
    }
}
