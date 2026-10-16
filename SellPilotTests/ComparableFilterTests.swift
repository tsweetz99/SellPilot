import XCTest
import SwiftData
@testable import SellPilot

private final class FilterStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.bodies.append(data)
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct StaticResearch: MarketResearchService {
    var comparables: [MarketComparable]
    func research(item: SellItem) async throws -> [MarketComparable] { comparables }
}
private struct StaticFilter: ComparableFilterService {
    var result: Result<Set<Int>, ServiceError>
    func matchingIndexes(in comparables: [MarketComparable], for item: SellItem) async throws -> Set<Int> { try result.get() }
}

final class ComparableFilterTests: XCTestCase {
    override func setUp() { FilterStub.bodies = []; FilterStub.handler = nil }

    private func comps(_ prices: [Double], titles: [String]? = nil) -> [MarketComparable] {
        prices.enumerated().map { MarketComparable(title: titles?[$0.offset] ?? "DeWalt DCF887B #\($0.offset)", marketplace: .ebay, price: $0.element, status: .active, condition: .good, date: Date()) }
    }
    private func item() -> SellItem {
        var item = SellItem(); item.title = "DEWALT 20V MAX XR Impact Driver"; item.brand = "DEWALT"; item.model = "DCF887B"; item.sellerNotes = "Tool only, no battery."; return item
    }
    private func filter() -> ClaudeComparableFilter {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FilterStub.self]
        return ClaudeComparableFilter(configuration: .init(apiKey: "k", retryDelay: .milliseconds(1)), session: URLSession(configuration: config))
    }
    private func reply(_ input: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "tool_use", "name": "report_matches", "input": input]]])
    }

    func testRequestListsNumberedTitlesAndTheSellersConfigurationWithoutPhotos() async throws {
        FilterStub.handler = { _ in (200, self.reply(["matching_indexes": [0, 2, 99, 2, -1], "notes": "x"])) }
        let titles = ["Kit with battery", "Bare tool", "Charger only"]
        let indexes = try await filter().matchingIndexes(in: comps([100, 45, 20], titles: titles), for: item())
        XCTAssertEqual(indexes, [0, 2], "out-of-range and duplicate indexes are ignored")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FilterStub.bodies[0]) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001"); XCTAssertEqual((body["tool_choice"] as? [String: String])?["type"], "auto")
        let text = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        XCTAssertTrue(text.contains("0. Kit with battery")); XCTAssertTrue(text.contains("1. Bare tool")); XCTAssertTrue(text.contains("Tool only, no battery."))
        XCTAssertTrue(text.contains("DCF887B")); XCTAssertFalse(text.contains("$"), "prices are not sent, so they cannot bias matching")
    }

    func testWrapperKeepsOnlyConfirmedListingsAndMarksThemVerified() async throws {
        let all = comps([100, 45, 20, 50, 48, 120])
        let service = FilteredMarketResearchService(base: StaticResearch(comparables: all), filter: StaticFilter(result: .success([1, 3, 4])))
        let result = try await service.research(item: item())
        XCTAssertEqual(result.map(\.price), [45, 50, 48]); XCTAssertTrue(result.allSatisfy { $0.verifiedMatch == true })
        let pricing = try await AskingPricePricingService().analyze(item: item(), comparables: result)
        XCTAssertTrue(pricing.dataSourceSummary.contains("same model and configuration"))
    }

    func testWrapperFallsBackToUnverifiedWhenTooFewMatchOrTheFilterFails() async throws {
        let all = comps([100, 45, 20, 50])
        for outcome in [Result<Set<Int>, ServiceError>.success([1]), .failure(.invalid("offline"))] {
            let result = try await FilteredMarketResearchService(base: StaticResearch(comparables: all), filter: StaticFilter(result: outcome)).research(item: item())
            XCTAssertEqual(result.count, 4); XCTAssertTrue(result.allSatisfy { $0.verifiedMatch == nil })
            let pricing = try await AskingPricePricingService().analyze(item: item(), comparables: result)
            XCTAssertTrue(pricing.dataSourceSummary.contains("not checked"))
        }
    }

    func testUnreadableFilterReplyThrows() async {
        FilterStub.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"hi"}]}"#.utf8)) }
        do { _ = try await filter().matchingIndexes(in: comps([1, 2, 3]), for: item()); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not be read")) }
    }

    private struct SwitchableResearch: MarketResearchService {
        var comparables: [MarketComparable]; var fail = false
        func research(item: SellItem) async throws -> [MarketComparable] { if fail { throw ServiceError.invalid("No internet connection.") }; return comparables }
    }

    @MainActor func testRefreshUpdatesPricesAndClearsListingsButKeepsDataOnFailure() async throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var services = AppServices()
        var seed = SellItem(); seed.title = "Chair"; seed.workflowStep = 3; seed.status = .draft
        seed.photos = [try SellItemPhoto(originalData: Data([1]))]; seed.askingPrice = 5
        seed.listings = [ListingDraft(marketplace: .ebay, title: "t", description: "d", price: 5, condition: .good, category: "c", keywords: [], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "", photoOrder: [seed.photos[0].id])]
        services.research = SwitchableResearch(comparables: comps([40, 50, 60, 70, 80])); services.pricing = AskingPricePricingService()
        let workflow = SellingWorkflow(item: seed, store: ItemStore(context: container.mainContext), services: services)
        await workflow.refreshMarketPrices()
        XCTAssertNil(workflow.error); XCTAssertEqual(workflow.item.workflowStep, 2); XCTAssertTrue(workflow.item.listings.isEmpty)
        XCTAssertEqual(workflow.item.askingPrice, 54); XCTAssertEqual(workflow.item.pricing?.source, "ebay-browse-active"); XCTAssertEqual(workflow.item.status, .draft)

        let kept = workflow.item
        var failing = services; failing.research = SwitchableResearch(comparables: [], fail: true)
        let second = SellingWorkflow(item: kept, store: ItemStore(context: container.mainContext), services: failing)
        await second.refreshMarketPrices()
        XCTAssertEqual(second.item.pricing, kept.pricing); XCTAssertEqual(second.item.askingPrice, kept.askingPrice)
        XCTAssertTrue(try XCTUnwrap(second.error).contains("saved prices were kept"))
        var sold = kept; sold.status = .sold
        let third = SellingWorkflow(item: sold, store: ItemStore(context: container.mainContext), services: services)
        await third.refreshMarketPrices(); XCTAssertEqual(third.item.pricing, kept.pricing, "sold items are never repriced")
    }
}
