import Foundation
import Observation
@MainActor @Observable final class SellingWorkflow {
    var item: SellItem
    var busy = false
    var error: String?
    var notice: String?
    /// Set when automatic identification failed, so the capture screen can offer manual entry.
    var identificationFailed = false
    let services: AppServices
    let store: ItemStore
    init(item: SellItem, store: ItemStore, services: AppServices) { self.item = item; self.store = store; self.services = services }
    @discardableResult func save() -> Bool { let saved = store.save(item); if !saved { error = store.error }; return saved }
    func advance() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            switch item.workflowStep {
            case 0:
                identificationFailed = false
                let result: ProductIdentification
                do { result = try await services.identification.identify(photos: item.orderedPhotos) }
                catch { identificationFailed = true; throw error }
                item.identification = result; apply(result.product); item.condition = result.detectedCondition; item.subcategory = result.subcategory; item.color = result.color; item.confidenceScore = result.confidenceScore
            case 1:
                guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.invalid("Enter a product name.") }
                item.comparables = []; item.pricing = nil; item.listings = []; item.status = .draft
                // Market data is a convenience: if it fails, the seller can still set their own price.
                do {
                    item.comparables = try await services.research.research(item: item)
                    item.pricing = try await services.pricing.analyze(item: item, comparables: item.comparables)
                } catch { item.comparables = []; item.pricing = nil; self.error = "Couldn't get market prices: \(error.localizedDescription) You can enter your own asking price." }
                item.recommendations = try await services.marketplaces.recommend(item: item)
                item.askingPrice = item.pricing?.price(for: item.pricingStrategy) ?? 0
                item.selectedMarketplaces = item.recommendations.sorted { $0.rank < $1.rank }.prefix(2).map(\.marketplace)
            case 2:
                guard item.askingPrice > 0, item.askingPrice.isFinite else { throw ServiceError.invalid("Enter a positive asking price.") }
                guard !item.selectedMarketplaces.isEmpty else { throw ServiceError.invalid("Choose at least one marketplace.") }
                item.selectedMarketplace = item.selectedMarketplaces[0]
                var drafts: [ListingDraft] = []
                for market in item.selectedMarketplaces { drafts.append(try await services.listings.generate(item: item, marketplace: market)) }
                item.listings = drafts; item.status = .ready
            default: break
            }
            item.workflowStep = min(item.workflowStep + 1, SellItem.lastStep); save()
        } catch { self.error = error.localizedDescription }
    }
    /// Moves past identification without a result so the seller can describe the item themselves.
    func skipIdentification() {
        guard item.workflowStep == 0, !item.photos.isEmpty else { return }
        item.identification = nil; item.confidenceScore = 0
        if item.title == "Untitled item" { item.title = "" }
        identificationFailed = false
        item.workflowStep = 1; save()
    }
    /// Re-fetches market data and price suggestions for a saved item, keeping the seller's marketplace choices.
    /// Existing data is kept if the refresh fails. Listings are cleared because they contain the old price.
    func refreshMarketPrices() async {
        guard !busy, item.status == .draft || item.status == .ready, item.workflowStep >= 2 else { return }
        busy = true; defer { busy = false }
        do {
            let comparables = try await services.research.research(item: item)
            let pricing = try await services.pricing.analyze(item: item, comparables: comparables)
            if item.recommendations.isEmpty { item.recommendations = try await services.marketplaces.recommend(item: item) }
            item.comparables = comparables; item.pricing = pricing
            item.askingPrice = pricing.price(for: item.pricingStrategy)
            item.listings = []; item.status = .draft; item.workflowStep = 2
            save()
        } catch { self.error = "Couldn't refresh market prices: \(error.localizedDescription) Your saved prices were kept." }
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
