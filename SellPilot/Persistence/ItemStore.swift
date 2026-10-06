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
    init(context: ModelContext) { self.context = context; reload() }
    func reload() {
        do {
            let rows = try context.fetch(FetchDescriptor<StoredSellItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            items = try rows.map { try JSONDecoder().decode(SellItem.self, from: $0.payload) }
        } catch { self.error = "Could not load saved items: \(error.localizedDescription)" }
    }
    @discardableResult func save(_ value: SellItem) -> Bool {
        do {
            var item = value; item.updatedAt = Date()
            let id = item.id
            let descriptor = FetchDescriptor<StoredSellItem>(predicate: #Predicate { $0.id == id })
            if let row = try context.fetch(descriptor).first { row.payload = try JSONEncoder().encode(item); row.updatedAt = item.updatedAt }
            else { context.insert(try StoredSellItem(item: item)) }
            try context.save(); items.removeAll { $0.id == item.id }; items.append(item); items.sort { $0.updatedAt > $1.updatedAt }; return true
        } catch { context.rollback(); self.error = "Could not save: \(error.localizedDescription)"; return false }
    }
}
