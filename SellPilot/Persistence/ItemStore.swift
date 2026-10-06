import SwiftData
import Foundation

@Model final class StoredSellItem {
    @Attribute(.unique) var id: UUID
    var updatedAt: Date
    @Attribute(.externalStorage) var payload: Data
    init(item: SellItem) throws { id = item.id; updatedAt = item.updatedAt; payload = try JSONEncoder().encode(item) }
}
@MainActor @Observable final class ItemStore {
    private let context: ModelContext
    var items: [SellItem] = []
    var error: String?
    private var loadedCleanly = false
    init(context: ModelContext) { self.context = context; reload() }
    func reload() {
        do {
            let rows = try context.fetch(FetchDescriptor<StoredSellItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            var loaded: [SellItem] = []
            for row in rows {
                // Decoding moves any legacy inline photo bytes to files; rewrite the payload without them.
                let tracker = PhotoMigrationTracker()
                let decoder = JSONDecoder(); decoder.userInfo[.photoMigration] = tracker
                let item = try decoder.decode(SellItem.self, from: row.payload)
                if tracker.count > 0 { row.payload = try JSONEncoder().encode(item) }
                loaded.append(item)
            }
            if context.hasChanges { try context.save() }
            items = loaded; loadedCleanly = true
        } catch { context.rollback(); loadedCleanly = false; self.error = "Could not load saved items: \(error.localizedDescription)" }
    }
    /// Deletes photo files no saved item references. Call once at launch, never from tests that share the real photo folder.
    /// Skipped unless every saved item loaded, so a decode failure can never cause photos to be deleted.
    @discardableResult func sweepOrphanedPhotos() -> Int {
        guard loadedCleanly else { return 0 }
        return PhotoStorage.shared.sweep(keeping: Set(items.flatMap { $0.photos.map(\.id) }))
    }
    @discardableResult func save(_ value: SellItem) -> Bool {
        do {
            var item = value; item.updatedAt = Date()
            let id = item.id
            let removedPhotos = Set(items.first { $0.id == id }?.photos.map(\.id) ?? []).subtracting(item.photos.map(\.id))
            let descriptor = FetchDescriptor<StoredSellItem>(predicate: #Predicate { $0.id == id })
            if let row = try context.fetch(descriptor).first { row.payload = try JSONEncoder().encode(item); row.updatedAt = item.updatedAt }
            else { context.insert(try StoredSellItem(item: item)) }
            try context.save(); items.removeAll { $0.id == item.id }; items.append(item); items.sort { $0.updatedAt > $1.updatedAt }
            PhotoStorage.shared.delete(ids: removedPhotos)
            return true
        } catch { context.rollback(); self.error = "Could not save: \(error.localizedDescription)"; return false }
    }
}
