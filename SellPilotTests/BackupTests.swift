import XCTest
import SwiftData
@testable import SellPilot

@MainActor final class BackupTests: XCTestCase {
    private var root: URL!
    private var containers: [ModelContainer] = []
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PhotoStorage.shared = PhotoStorage(root: root.appendingPathComponent("photos"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store() throws -> ItemStore {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return ItemStore(context: container.mainContext)
    }
    private func item(_ title: String, photos: Int = 2, updated: Date = Date()) throws -> SellItem {
        var item = SellItem(); item.title = title; item.updatedAt = updated
        item.photos = try (0..<photos).map { try SellItemPhoto(originalData: Data(repeating: UInt8($0 + 1), count: 3_000), previewData: Data(repeating: 9, count: 100)) }
        return item
    }
    private var file: URL { root.appendingPathComponent("test.sellpilot") }
    private func emptyPhotos() -> PhotoStorage { PhotoStorage(root: root.appendingPathComponent("restored-\(UUID().uuidString)")) }

    func testRoundTripKeepsItemsAndPhotos() throws {
        let first = try item("Skates"), second = try item("Book", photos: 1)
        try BackupArchive.write(items: [first, second], photos: PhotoStorage.shared, to: file)
        let fresh = emptyPhotos()
        let result = try BackupArchive.read(from: file, photos: fresh) { _ in true }
        XCTAssertEqual(result.all.map(\.title), ["Skates", "Book"]); XCTAssertEqual(result.photos, 3)
        for photo in first.photos + second.photos {
            XCTAssertEqual(fresh.read(id: photo.id, kind: .original), photo.originalData); XCTAssertEqual(fresh.read(id: photo.id, kind: .preview), photo.previewData)
        }
        XCTAssertEqual(result.all[0].id, first.id)
    }

    func testOnlyPhotosOfTakenItemsAreRestored() throws {
        let kept = try item("Kept"), taken = try item("Taken")
        try BackupArchive.write(items: [kept, taken], photos: PhotoStorage.shared, to: file)
        let fresh = emptyPhotos()
        let result = try BackupArchive.read(from: file, photos: fresh) { $0.title == "Taken" }
        XCTAssertEqual(result.taken.map(\.title), ["Taken"])
        XCTAssertTrue(fresh.exists(id: taken.photos[0].id, kind: .original)); XCTAssertFalse(fresh.exists(id: kept.photos[0].id, kind: .original))
    }

    func testRestoreIntoAnEmptyStoreBringsEverythingBackWithOriginalDates() async throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try item("Skates", updated: old)
        try BackupArchive.write(items: [original], photos: PhotoStorage.shared, to: file)
        PhotoStorage.shared.delete(ids: original.photos.map(\.id))          // the app was deleted
        let target = try store()
        let summary = try await BackupService.restore(from: file, into: target)
        XCTAssertEqual(summary, BackupSummary(added: 1, updated: 0, kept: 0, photos: 2))
        XCTAssertEqual(target.items.map(\.title), ["Skates"]); XCTAssertEqual(target.items[0].updatedAt.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(target.items[0].photos[0].originalData, Data(repeating: 1, count: 3_000))
    }

    func testANewerCopyOnThePhoneIsNeverReplacedByAnOlderBackup() async throws {
        let target = try store()
        var local = try item("Edited later", photos: 0); local.updatedAt = Date(); XCTAssertTrue(target.save(local))
        var older = local; older.title = "Old backup"; older.updatedAt = Date(timeIntervalSinceNow: -86_400)
        let newer = try item("Brand new", photos: 0)
        try BackupArchive.write(items: [older, newer], photos: PhotoStorage.shared, to: file)
        let summary = try await BackupService.restore(from: file, into: target)
        XCTAssertEqual(summary, BackupSummary(added: 1, updated: 0, kept: 1, photos: 0))
        XCTAssertEqual(Set(target.items.map(\.title)), ["Edited later", "Brand new"])
    }

    func testAnOlderLocalCopyIsUpdatedFromANewerBackup() async throws {
        let target = try store()
        var local = try item("Before", photos: 0); XCTAssertTrue(target.save(local))
        local.title = "After"; local.updatedAt = Date(timeIntervalSinceNow: 3_600)
        try BackupArchive.write(items: [local], photos: PhotoStorage.shared, to: file)
        let summary = try await BackupService.restore(from: file, into: target)
        XCTAssertEqual(summary.updated, 1); XCTAssertEqual(target.items.map(\.title), ["After"])
    }

    func testFilesThatAreNotBackupsOrAreCutOffAreRefusedAndChangeNothing() async throws {
        try Data("hello".utf8).write(to: file)
        XCTAssertThrowsError(try BackupArchive.read(from: file, photos: emptyPhotos()) { _ in true }) { XCTAssertEqual($0 as? BackupError, .notABackup) }
        let good = try item("Skates")
        try BackupArchive.write(items: [good], photos: PhotoStorage.shared, to: file)
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count - 500).write(to: file)               // cut off in the middle of a photo
        let target = try store()
        do { _ = try await BackupService.restore(from: file, into: target); XCTFail("should be refused") } catch { XCTAssertEqual(error as? BackupError, .damaged) }
        XCTAssertTrue(target.items.isEmpty, "a damaged backup restores nothing")
    }

    func testHostileRecordNamesCannotWriteOutsideThePhotoFolder() throws {
        let good = try item("Skates", photos: 1)
        try BackupArchive.write(items: [good], photos: PhotoStorage.shared, to: file)
        var bytes = try Data(contentsOf: file)
        func record(_ name: String, _ data: Data) {
            var length = UInt32(name.utf8.count).bigEndian, dataLength = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }; bytes.append(Data(name.utf8))
            withUnsafeBytes(of: &dataLength) { bytes.append(contentsOf: $0) }; bytes.append(data)
        }
        record("photos/../../escape.txt", Data("x".utf8)); record("../escape.txt", Data("x".utf8)); record("photos/not-a-uuid.original", Data("x".utf8))
        try bytes.write(to: file)
        let fresh = emptyPhotos()
        let result = try BackupArchive.read(from: file, photos: fresh) { _ in true }
        XCTAssertEqual(result.photos, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: fresh.root.path)).count, 2, "only the one photo (original and preview)")
    }

    func testAbsurdRecordSizesAreRejectedBeforeAnyMemoryIsReserved() throws {
        var bytes = Data("SPBK1\n".utf8)
        var nameLength = UInt32(10).bigEndian, huge = UInt64.max.bigEndian
        withUnsafeBytes(of: &nameLength) { bytes.append(contentsOf: $0) }; bytes.append(Data("items.json".utf8))
        withUnsafeBytes(of: &huge) { bytes.append(contentsOf: $0) }
        try bytes.write(to: file)
        XCTAssertThrowsError(try BackupArchive.read(from: file, photos: emptyPhotos()) { _ in true }) { XCTAssertEqual($0 as? BackupError, .damaged) }
    }

    func testReminderOnlyWhenThereIsSomethingToLose() {
        UserDefaults.standard.removeObject(forKey: "lastBackupDate")
        XCTAssertFalse(BackupService.needsReminder(itemCount: 0)); XCTAssertTrue(BackupService.needsReminder(itemCount: 3))
        BackupService.lastBackup = Date(); XCTAssertFalse(BackupService.needsReminder(itemCount: 3))
        XCTAssertTrue(BackupService.needsReminder(itemCount: 3, now: Date(timeIntervalSinceNow: 15 * 86_400)))
        UserDefaults.standard.removeObject(forKey: "lastBackupDate")
    }
}
