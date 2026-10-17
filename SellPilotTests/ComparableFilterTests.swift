import XCTest
import SwiftData
@testable import SellPilot

private struct StaticResearch: MarketResearchService {
    var comparables: [MarketComparable]
    func research(item: SellItem) async throws -> [MarketComparable] { comparables }
}
private struct StaticFilter: ComparableFilterService {
    var result: Result<Set<Int>, ServiceError>
    func matchingIndexes(in comparables: [MarketComparable], for item: SellItem) async throws -> Set<Int> { try result.get() }
}

final class ComparableFilterTests: XCTestCase {
    private func comps(_ prices: [Double], titles: [String]? = nil) -> [MarketComparable] {
        prices.enumerated().map { MarketComparable(title: titles?[$0.offset] ?? "DeWalt DCF887B #\($0.offset)", marketplace: .ebay, price: $0.element, status: .active, condition: .good, date: Date()) }
    }
    private func item() -> SellItem {
        var item = SellItem(); item.title = "DEWALT 20V MAX XR Impact Driver"; item.brand = "DEWALT"; item.model = "DCF887B"; item.sellerNotes = "Tool only, no battery."; return item
    }
    func testWrapperKeepsOnlyConfirmedListingsAndMarksThemVerified() async throws {
        let all = comps([100, 45, 20, 50, 48, 120])
        let service = FilteredMarketResearchService(base: StaticResearch(comparables: all), filter: StaticFilter(result: .success([1, 3, 4])))
        let result = try await service.research(item: item())
        XCTAssertEqual(result.map(\.price), [45, 50, 48]); XCTAssertTrue(result.allSatisfy { $0.verifiedMatch == true })
        let pricing = try await AskingPricePricingService().analyze(item: item(), comparables: result)
        XCTAssertTrue(pricing.dataSourceSummary.contains("matched to your item"))
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

    // MARK: Title rules (no AI)

    private func bareItem() -> SellItem { var item = SellItem(); item.title = "DEWALT 20V MAX XR Impact Driver"; item.brand = "DEWALT"; item.model = "DCF887B"; item.sellerNotes = "Tool only, no battery."; return item }
    private func titles(_ t: [String]) -> [MarketComparable] { comps(t.map { _ in 10 }, titles: t) }

    func testTitleFilterKeepsTheSameModelInTheSameConfiguration() async throws {
        let listings = titles([
            "DeWalt DCF887B 20V Impact Driver (Tool Only)",                 // 0 keep
            "DEWALT DCF887 20V 1/4\" Impact Driver w/ Battery and Charger", // 1 kit, seller has the bare tool
            "DEWALT DCF887D2 Impact Driver Kit 2 batteries",                 // 2 kit
            "DEWALT DCF887B Replacement Battery Charger only",               // 3 accessory
            "DeWalt DCF887B for parts not working",                          // 4 parts
            "Lot of 3 DeWalt DCF887B impact drivers",                        // 5 lot
            "DeWalt DCF840 Impact Driver bare tool",                         // 6 different model
            "Dewalt DCF-887-B bare tool",                                    // 7 keep (punctuation differs)
            "DEWALT DCF887B Brushless Impact Driver",                        // 8 keep (config not stated)
        ])
        let matches = try await TitleComparableFilter().matchingIndexes(in: listings, for: bareItem())
        XCTAssertEqual(matches, [0, 7, 8])
    }

    func testTitleFilterFollowsTheSellersConfigurationBothWays() async throws {
        var kitItem = bareItem(); kitItem.sellerNotes = "Comes with battery and charger in a kit."
        let listings = titles(["DEWALT DCF887B Impact Driver (Tool Only)", "DEWALT DCF887 Impact Driver Kit with Battery and Charger", "DEWALT DCF887B Impact Driver"])
        let matches = try await TitleComparableFilter().matchingIndexes(in: listings, for: kitItem)
        XCTAssertEqual(matches, [1, 2], "a seller with the kit does not compare against bare tools")
        var parts = bareItem(); parts.condition = .parts
        let broken = try await TitleComparableFilter().matchingIndexes(in: titles(["DeWalt DCF887B for parts only", "DeWalt DCF887B tool only"]), for: parts)
        XCTAssertEqual(broken, [0, 1], "an item for parts is compared with other parts listings")
    }

    func testWithoutAModelNumberListingsMustShareMostOfTheItemsWords() async throws {
        var item = SellItem(); item.title = "Oak side table"; item.brand = ""
        let matches = try await TitleComparableFilter().matchingIndexes(in: titles(["Solid oak side table vintage", "Oak coffee table", "Pine side table", "Oak Side Table with drawer"]), for: item)
        XCTAssertEqual(matches, [0, 3])
        var short = SellItem(); short.title = "Chair"
        let everything = try await TitleComparableFilter().matchingIndexes(in: titles(["Anything", "Else"]), for: short)
        XCTAssertEqual(everything, [0, 1], "too little to judge by, so nothing is excluded")
    }

    func testModelKeysAllowTheSuffixVariantButNotShortCodes() {
        XCTAssertEqual(TitleComparableFilter.modelKeys("DCF887B"), ["dcf887b", "dcf887"])
        XCTAssertEqual(TitleComparableFilter.modelKeys("2804-20"), ["280420"])
        XCTAssertEqual(TitleComparableFilter.modelKeys("X1"), [])
        XCTAssertEqual(TitleComparableFilter.modelKeys("Unknown"), [])
        XCTAssertTrue(ItemConfiguration(text: "Tool Only").bare); XCTAssertTrue(ItemConfiguration(text: "3 pack of pens").lot); XCTAssertFalse(ItemConfiguration(text: "Blotter paper").lot)
    }

    private struct SwitchableResearch: MarketResearchService {
        var comparables: [MarketComparable]; var fail = false
        func research(item: SellItem) async throws -> [MarketComparable] { if fail { throw ServiceError.invalid("No internet connection.") }; return comparables }
    }

    @MainActor func testRefreshUpdatesPricesKeepsListingsAndKeepsDataOnFailure() async throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var services = AppServices()
        var seed = SellItem(); seed.title = "Chair"; seed.workflowStep = 3; seed.status = .draft
        seed.photos = [try SellItemPhoto(originalData: Data([1]))]; seed.askingPrice = 5
        seed.listings = [ListingDraft(marketplace: .ebay, title: "t", description: "d", price: 5, condition: .good, category: "c", keywords: [], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "", photoOrder: [seed.photos[0].id])]
        services.research = SwitchableResearch(comparables: comps([40, 50, 60, 70, 80])); services.pricing = AskingPricePricingService()
        let workflow = SellingWorkflow(item: seed, store: ItemStore(context: container.mainContext), services: services)
        await workflow.refreshMarketPrices()
        XCTAssertNil(workflow.error); XCTAssertEqual(workflow.item.workflowStep, 2)
        XCTAssertEqual(workflow.item.listings.count, 1, "listings stay until regenerated, so the Ready screen never loses what it is showing")
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

    @MainActor func testALiveEbayListingBlocksRepricingAndRegenerating() async throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var services = AppServices(); services.research = SwitchableResearch(comparables: comps([40, 50, 60, 70, 80])); services.pricing = AskingPricePricingService()
        var seed = SellItem(); seed.title = "Chair"; seed.workflowStep = 3; seed.status = .ready; seed.askingPrice = 5; seed.selectedMarketplaces = [.ebay]
        seed.photos = [try SellItemPhoto(originalData: Data([1]))]
        var live = ListingDraft(marketplace: .ebay, title: "t", description: "d", price: 5, condition: .good, category: "c", keywords: [], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "", photoOrder: [seed.photos[0].id])
        live.ebayOfferID = "O"; live.ebayListingID = "L"; seed.listings = [live]
        let workflow = SellingWorkflow(item: seed, store: ItemStore(context: container.mainContext), services: services)
        await workflow.refreshMarketPrices()
        XCTAssertTrue(try XCTUnwrap(workflow.error).contains("End the eBay listing")); XCTAssertEqual(workflow.item.askingPrice, 5); XCTAssertEqual(workflow.item.workflowStep, 3)
        workflow.error = nil; workflow.item.workflowStep = 2
        await workflow.advance()
        XCTAssertTrue(try XCTUnwrap(workflow.error).contains("live eBay listing")); XCTAssertEqual(workflow.item.listings[0].ebayListingID, "L", "the live listing reference is never replaced")
        workflow.error = nil; workflow.item.workflowStep = 1
        await workflow.advance()
        XCTAssertNotNil(workflow.error); XCTAssertEqual(workflow.item.listings[0].ebayListingID, "L")
    }
}
