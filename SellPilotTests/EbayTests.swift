import XCTest
import SwiftData
@testable import SellPilot

private final class EbayStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.bodies.append(data)
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EbayTests: XCTestCase {
    override func setUp() { EbayStub.requests = []; EbayStub.bodies = []; EbayStub.handler = nil }

    private func service() -> EbayBrowseMarketResearchService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EbayStub.self]
        return EbayBrowseMarketResearchService(configuration: .init(credentials: .init(appID: "app-id", certID: "cert-id")), session: URLSession(configuration: config))
    }
    private func tokenReply() -> Data { Data(#"{"access_token":"tok-1","expires_in":7200}"#.utf8) }
    private func listings(_ prices: [String], currency: String = "USD") -> Data {
        let items = prices.enumerated().map { i, p in ["itemId": "v1|\(i)", "title": "DeWalt DCF887B #\(i)", "price": ["value": p, "currency": currency], "conditionId": "3000", "itemWebUrl": "https://www.ebay.com/itm/\(i)", "itemCreationDate": "2026-10-01T12:00:00.000Z"] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["total": items.count, "itemSummaries": items])
    }
    private func item(brand: String = "DEWALT", model: String = "DCF887B", title: String = "DEWALT 20V MAX XR Impact Driver") -> SellItem {
        var item = SellItem(); item.brand = brand; item.model = model; item.title = title; item.condition = .good; return item
    }

    func testTokenAndSearchRequestsAreShapedForEbay() async throws {
        EbayStub.handler = { request in request.url!.path.contains("oauth2/token") ? (200, self.tokenReply()) : (200, self.listings(["40", "50", "60", "70", "80"])) }
        let comps = try await service().research(item: item())
        XCTAssertEqual(comps.count, 5); XCTAssertTrue(comps.allSatisfy { $0.status == .active && $0.marketplace == .ebay && $0.url != nil })

        let token = try XCTUnwrap(EbayStub.requests.first)
        XCTAssertEqual(token.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("app-id:cert-id".utf8).base64EncodedString())
        let form = String(decoding: EbayStub.bodies[0], as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=client_credentials")); XCTAssertTrue(form.contains("oauth%2Fapi_scope"))

        let search = try XCTUnwrap(EbayStub.requests.last)
        let components = try XCTUnwrap(URLComponents(url: search.url!, resolvingAgainstBaseURL: false))
        func param(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        XCTAssertEqual(param("q"), "DEWALT DCF887B"); XCTAssertEqual(search.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertEqual(search.value(forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID"), "EBAY_US")
        XCTAssertEqual(param("filter"), "buyingOptions:{FIXED_PRICE},priceCurrency:USD,conditions:{USED}", "the broad USED group, because specific IDs differ by category (books have no 3000)")
    }

    func testTokenIsReusedAndRefreshedOnceAfterA401() async throws {
        var searches = 0, tokens = 0
        EbayStub.handler = { request in
            if request.url!.path.contains("oauth2/token") { tokens += 1; return (200, Data(#"{"access_token":"tok-\#(tokens)","expires_in":7200}"#.utf8)) }
            searches += 1
            return searches == 1 ? (401, Data()) : (200, self.listings(["10", "20", "30", "40", "50"]))
        }
        let svc = service()
        _ = try await svc.research(item: item()); XCTAssertEqual(tokens, 2, "one refresh after the 401")
        _ = try await svc.research(item: item()); XCTAssertEqual(tokens, 2, "later searches reuse the cached token")
    }

    func testFallsBackToTheTitleWhenTheModelQueryFindsTooFew() async throws {
        EbayStub.handler = { request in
            if request.url!.path.contains("oauth2/token") { return (200, self.tokenReply()) }
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            return (200, q == "DEWALT DCF887B" ? self.listings(["50"]) : self.listings(["40", "50", "60", "70", "80", "90"]))
        }
        let comps = try await service().research(item: item())
        XCTAssertEqual(comps.count, 6)
    }

    func testParsingDropsNonUSDAndInvalidPrices() {
        let data = listings(["25.50", "0", "abc"]); let usd = EbayBrowseMarketResearchService.parse(data, fallbackCondition: .good)
        XCTAssertEqual(usd.map(\.price), [25.5])
        XCTAssertTrue(EbayBrowseMarketResearchService.parse(listings(["25"], currency: "EUR"), fallbackCondition: .good).isEmpty)
        XCTAssertTrue(EbayBrowseMarketResearchService.parse(Data("{}".utf8), fallbackCondition: .good).isEmpty)
    }

    func testQueryBuildingAndConditionMapping() {
        XCTAssertEqual(EbayBrowseMarketResearchService.queries(for: item()), ["DEWALT DCF887B", "DEWALT 20V MAX XR Impact Driver"])
        XCTAssertEqual(EbayBrowseMarketResearchService.queries(for: item(brand: "Unknown", model: "X1", title: "Thing")), ["X1", "Thing"])
        XCTAssertEqual(EbayBrowseMarketResearchService.queries(for: item(model: "", title: "  Oak   table ")), ["Oak table"])
        XCTAssertEqual(EbayBrowseMarketResearchService.conditionFilter(for: .new), "conditions:{NEW}")
        XCTAssertEqual(EbayBrowseMarketResearchService.conditionFilter(for: .good), "conditions:{USED}")
        XCTAssertEqual(EbayBrowseMarketResearchService.conditionFilter(for: .parts), "conditionIds:{7000}")
    }

    func testRejectedKeysAndMissingAccessGiveActionableMessages() async {
        EbayStub.handler = { _ in (401, Data(#"{"error":"invalid_client","error_description":"client authentication failed"}"#.utf8)) }
        do { _ = try await service().research(item: item()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Production")) }
        EbayStub.handler = { request in request.url!.path.contains("oauth2/token") ? (200, self.tokenReply()) : (403, Data(#"{"errors":[{"message":"Access denied"}]}"#.utf8)) }
        do { _ = try await service().research(item: item()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("denied access")) }
    }

    func testAskingPricePricingMathAndMinimums() async throws {
        func comps(_ prices: [Double]) -> [MarketComparable] { prices.map { MarketComparable(title: "x", marketplace: .ebay, price: $0, status: .active, condition: .good, date: Date()) } }
        let result = try await AskingPricePricingService().analyze(item: SellItem(), comparables: comps([40, 50, 60, 70, 80]))
        XCTAssertEqual(result.askingMedian, 60); XCTAssertEqual(result.sellFastPrice, 48); XCTAssertEqual(result.recommendedPrice, 54); XCTAssertEqual(result.maximizeReturnPrice, 60)
        XCTAssertEqual(result.soldMedian, 51); XCTAssertEqual(result.source, "ebay-browse-active"); XCTAssertLessThan(result.confidence, 0.5)
        XCTAssertTrue(result.dataSourceSummary.contains("not observed"))
        // Outliers (10% each end) don't move the median-based prices.
        let skewed = try await AskingPricePricingService().analyze(item: SellItem(), comparables: comps([1, 50, 52, 54, 56, 58, 60, 62, 64, 9_999]))
        XCTAssertEqual(skewed.askingMedian, 57)
        do { _ = try await AskingPricePricingService().analyze(item: SellItem(), comparables: comps([40, 50])); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("not enough")) }
    }

    private struct FailingResearch: MarketResearchService { func research(item: SellItem) async throws -> [MarketComparable] { throw ServiceError.invalid("No internet connection.") } }

    @MainActor func testMarketDataFailureStillLetsTheSellerSetAPrice() async throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var services = AppServices(); services.research = FailingResearch()
        var seed = SellItem(); seed.title = "Oak side table"; seed.workflowStep = 1
        let workflow = SellingWorkflow(item: seed, store: ItemStore(context: container.mainContext), services: services)
        await workflow.advance()
        XCTAssertEqual(workflow.item.workflowStep, 2); XCTAssertNil(workflow.item.pricing); XCTAssertEqual(workflow.item.askingPrice, 0)
        XCTAssertTrue(try XCTUnwrap(workflow.error).contains("enter your own asking price"))
        workflow.error = nil; await workflow.advance()
        XCTAssertEqual(workflow.item.workflowStep, 2, "no price yet"); XCTAssertNotNil(workflow.error)
        workflow.error = nil; workflow.item.askingPrice = 45; workflow.item.photos = [try SellItemPhoto(originalData: Data([1]))]
        await workflow.advance(); XCTAssertEqual(workflow.item.workflowStep, SellItem.lastStep); XCTAssertNil(workflow.error)
    }

    func testSearchFallsBackToNoConditionFilterWhenEbayRejectsIt() async throws {
        var filters: [String] = []
        EbayStub.handler = { request in
            if request.url!.path.contains("oauth2/token") { return (200, self.tokenReply()) }
            let filter = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "filter" }!.value!
            filters.append(filter)
            return filter.contains("condition") ? (400, Data(#"{"errors":[{"message":"The filter value is invalid"}]}"#.utf8)) : (200, self.listings(["10", "12", "14", "16", "18"]))
        }
        let comps = try await service().research(item: item())
        XCTAssertEqual(comps.count, 5)
        XCTAssertEqual(filters.count, 2); XCTAssertTrue(filters[0].contains("conditions:{USED}")); XCTAssertEqual(filters[1], "buyingOptions:{FIXED_PRICE},priceCurrency:USD")
    }
}
