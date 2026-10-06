import XCTest
import SwiftData
@testable import SellPilot
final class SellPilotTests: XCTestCase {
    override func setUp() { PhotoStorage.shared = PhotoStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")) }
    @MainActor func testCompleteWorkflowAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("items.store")
        let id = try await createSale(at: url)
        let reopened = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(url: url))
        let store = ItemStore(context: reopened.mainContext)
        let restored = try XCTUnwrap(store.items.first { $0.id == id })
        XCTAssertEqual(restored.status, .sold); XCTAssertEqual(restored.soldPrice, 91)
        XCTAssertEqual(restored.sellerNotes, "Battery not included. Visible scratch.")
        XCTAssertEqual(restored.photos.count, 1); XCTAssertEqual(restored.photos[0].originalData, PhotoImport.normalized(PhotoImport.demoPhoto()))
        XCTAssertEqual(restored.listings.count, 2); XCTAssertEqual(restored.comparables.count, 23)
        XCTAssertNotNil(restored.pricing); XCTAssertNotNil(restored.soldDate)
    }
    @MainActor private func createSale(at url: URL) async throws -> UUID {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(url: url))
        let store = ItemStore(context: container.mainContext)
        let workflow = SellingWorkflow(item: SellItem(), store: store, services: AppServices())
        workflow.item.photos = [try SellItemPhoto(originalData: try XCTUnwrap(PhotoImport.normalized(PhotoImport.demoPhoto())))]
        workflow.item.coverPhotoID = workflow.item.photos[0].id
        await workflow.advance(); XCTAssertEqual(workflow.item.workflowStep, 1); XCTAssertLessThan(workflow.item.confidenceScore, 0.7)
        await workflow.advance(); workflow.item.sellerNotes = "Battery not included. Visible scratch."
        await workflow.advance(); await workflow.advance(); await workflow.advance(); await workflow.advance()
        let original = workflow.item.photos[0].originalData
        await workflow.enhance(workflow.item.photos[0].id, style: .studio)
        XCTAssertEqual(original, workflow.item.photos[0].originalData)
        await workflow.advance(); XCTAssertNil(workflow.error); XCTAssertEqual(workflow.item.status, .ready)
        XCTAssertNotEqual(workflow.item.listings[0].description, workflow.item.listings[1].description)
        XCTAssertTrue(workflow.item.listings.allSatisfy { $0.description.contains("Battery not included") })
        await workflow.mockPublish(1); XCTAssertEqual(workflow.item.status, .ready)
        try workflow.activate(); XCTAssertEqual(workflow.item.status, .active)
        await workflow.markSold(price: 91); XCTAssertNil(workflow.error)
        return workflow.item.id
    }
    func testPricingUsesSoldSalesSeparatelyFromAsking() async throws {
        let comps = [MarketComparable(title: "A", marketplace: .ebay, price: 20, status: .sold, condition: .good, date: Date()), MarketComparable(title: "A", marketplace: .ebay, price: 40, status: .sold, condition: .good, date: Date()), MarketComparable(title: "A", marketplace: .facebook, price: 200, status: .active, condition: .good, date: Date())]
        let result = try await MockPricingAnalysisService().analyze(item: SellItem(), comparables: comps)
        XCTAssertEqual(result.soldMedian, 30); XCTAssertEqual(result.askingMedian, 200)
        XCTAssertLessThan(result.sellFastPrice, result.recommendedPrice); XCTAssertLessThan(result.recommendedPrice, result.maximizeReturnPrice)
    }
    func testExportOrderAndValidation() async throws {
        var item = SellItem(); item.title = "Chair"; item.askingPrice = 45
        item.photos = [try SellItemPhoto(originalData: Data([1])), try SellItemPhoto(originalData: Data([2]))]; item.coverPhotoID = item.photos[1].id
        let service = MockMarketplacePublishingService()
        var draft = try await MockListingGenerationService().generate(item: item, marketplace: .facebook)
        let prepared = try await service.prepareListing(draft, item: item)
        XCTAssertEqual(prepared.photos.map(\.id), [item.photos[1].id, item.photos[0].id])
        let urls = try ListingExportService().export(prepared)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: urls[2]), Data([2]))
        XCTAssertTrue(try String(contentsOf: urls[0], encoding: .utf8).contains("Chair"))
        draft.price = -1; XCTAssertThrowsError(try service.validateListing(draft))
    }
    @MainActor func testEmptyCaptureDoesNotAdvance() async throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let workflow = SellingWorkflow(item: SellItem(), store: ItemStore(context: container.mainContext), services: AppServices())
        await workflow.advance(); XCTAssertEqual(workflow.item.workflowStep, 0); XCTAssertNotNil(workflow.error)
    }
}
