import Foundation
import Observation
@MainActor @Observable final class SellingWorkflow {
    var item: SellItem
    var busy = false
    var error: String?
    var notice: String?
    let services: AppServices
    let store: ItemStore
    init(item: SellItem, store: ItemStore, services: AppServices) { self.item = item; self.store = store; self.services = services }
    @discardableResult func save() -> Bool { let saved = store.save(item); if !saved { error = store.error }; return saved }
    func advance() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            switch item.workflowStep {
            case 0:
                let result = try await services.identification.identify(photos: item.orderedPhotos)
                item.identification = result; apply(result.product); item.condition = result.detectedCondition; item.subcategory = result.subcategory; item.color = result.color; item.confidenceScore = result.confidenceScore
            case 1:
                guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.invalid("Enter a product name.") }
                item.comparables = []; item.pricing = nil; item.listings = []; item.status = .draft
            case 2:
                item.comparables = try await services.research.research(item: item)
                item.pricing = try await services.pricing.analyze(item: item, comparables: item.comparables)
                item.recommendations = try await services.marketplaces.recommend(item: item)
                item.askingPrice = item.pricing?.price(for: item.pricingStrategy) ?? 0
            case 4:
                guard item.askingPrice > 0, item.askingPrice.isFinite else { throw ServiceError.invalid("Enter a positive asking price.") }
            case 5:
                guard !item.selectedMarketplaces.isEmpty else { throw ServiceError.invalid("Choose at least one marketplace.") }
                item.selectedMarketplace = item.selectedMarketplaces[0]
            case 6:
                var drafts: [ListingDraft] = []
                for market in item.selectedMarketplaces { drafts.append(try await services.listings.generate(item: item, marketplace: market)) }
                item.listings = drafts; item.status = .ready
            default: break
            }
            item.workflowStep = min(item.workflowStep + 1, 7); save()
        } catch { self.error = error.localizedDescription }
    }
    func apply(_ match: ProductMatch) { item.title = match.title; item.brand = match.brand; item.model = match.model; item.category = match.category }
    func enhance(_ photoID: UUID, style: EnhancementStyle) async {
        guard let index = item.photos.firstIndex(where: { $0.id == photoID }) else { return }
        do { item.photos[index].enhancement = try await services.enhancement.preview(photo: item.photos[index], style: style); save() } catch { self.error = error.localizedDescription }
    }
    func mockPublish(_ index: Int) async {
        do { let receipt = try await services.publishing.publishListing(item.listings[index]); item.listings[index].mockPublishReference = receipt.reference; save(); notice = "Mock publish complete. No listing was posted. Confirm publication separately to track it as Active." } catch { self.error = error.localizedDescription }
    }
    func activate() throws {
        guard !item.listings.isEmpty else { throw ServiceError.invalid("Generate a listing first.") }
        for draft in item.listings { try services.publishing.validateListing(draft) }
        item.status = .active; save()
    }
    func markSold(price: Double) async {
        do {
            guard item.status == .active else { throw ServiceError.invalid("Only Active items can be marked Sold.") }
            guard price >= 0, price.isFinite else { throw ServiceError.invalid("Enter a valid sold price.") }
            for draft in item.listings { try await services.publishing.markSold(draft, price: price) }
            item.soldPrice = price; item.soldDate = Date(); item.status = .sold; save()
        } catch { self.error = error.localizedDescription }
    }
}
