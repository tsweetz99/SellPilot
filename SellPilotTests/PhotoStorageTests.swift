import XCTest
import SwiftData
@testable import SellPilot

@MainActor final class PhotoStorageTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        PhotoStorage.shared = PhotoStorage(root: root)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testPhotoBytesLiveOnDiskNotInPayload() throws {
        let bytes = Data(repeating: 7, count: 500_000)
        var item = SellItem(); item.photos = [try SellItemPhoto(originalData: bytes, previewData: Data([9]))]
        XCTAssertEqual(item.photos[0].originalData, bytes); XCTAssertEqual(item.photos[0].previewData, Data([9]))
        XCTAssertEqual(item.photos[0].originalByteCount, 500_000)
        let payload = try JSONEncoder().encode(item)
        XCTAssertLessThan(payload.count, 5_000)
        let decoded = try JSONDecoder().decode(SellItem.self, from: payload)
        XCTAssertEqual(decoded.photos[0].originalData, bytes)
    }

    func testLegacyInlinePayloadMigratesToFilesAndStoreRewritesIt() throws {
        let bytes = Data(repeating: 3, count: 200_000), preview = Data(repeating: 4, count: 50_000)
        var item = SellItem(); item.title = "Legacy"
        let photo = try SellItemPhoto(originalData: Data([0]))
        item.photos = [photo]
        // Build the old payload shape: bytes inline on the photo.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        var photos = try XCTUnwrap(json["photos"] as? [[String: Any]])
        photos[0]["originalData"] = bytes.base64EncodedString(); photos[0]["previewData"] = preview.base64EncodedString()
        json["photos"] = photos
        let legacyPayload = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.removeItem(at: root); PhotoStorage.shared = PhotoStorage(root: root)

        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let row = try StoredSellItem(item: item); row.payload = legacyPayload
        container.mainContext.insert(row); try container.mainContext.save()

        let store = ItemStore(context: container.mainContext)
        let loaded = try XCTUnwrap(store.items.first)
        XCTAssertEqual(loaded.photos[0].originalData, bytes); XCTAssertEqual(loaded.photos[0].previewData, preview)
        XCTAssertLessThan(row.payload.count, 5_000, "payload should be rewritten without inline photos")
        XCTAssertNil(store.error)
    }

    func testSavingRemovesFilesOfDeletedPhotos() throws {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        do {
            let store = ItemStore(context: container.mainContext)
            var item = SellItem(); item.photos = [try SellItemPhoto(originalData: Data([1])), try SellItemPhoto(originalData: Data([2]))]
            XCTAssertTrue(store.save(item))
            let removed = item.photos.removeLast()
            XCTAssertTrue(store.save(item))
            XCTAssertFalse(removed.isAvailable); XCTAssertTrue(item.photos[0].isAvailable)
        }
    }

    func testSweepKeepsReferencedAndIgnoresForeignFiles() throws {
        let keep = try SellItemPhoto(originalData: Data([1]), previewData: Data([1])), drop = try SellItemPhoto(originalData: Data([2]))
        try Data([5]).write(to: root.appendingPathComponent("notes.txt"))
        XCTAssertEqual(PhotoStorage.shared.sweep(keeping: [keep.id]), 1)
        XCTAssertTrue(keep.isAvailable); XCTAssertFalse(drop.isAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.txt").path))
    }

    func testSweepSkippedWhenAnItemFailsToLoad() throws {
        let photo = try SellItemPhoto(originalData: Data([1]))
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let row = try StoredSellItem(item: SellItem()); row.payload = Data("not json".utf8)
        container.mainContext.insert(row); try container.mainContext.save()
        do {
            let store = ItemStore(context: container.mainContext)
            XCTAssertNotNil(store.error); XCTAssertEqual(store.sweepOrphanedPhotos(), 0)
        }
        XCTAssertTrue(photo.isAvailable)
    }
}
