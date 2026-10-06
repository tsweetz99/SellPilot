import Foundation
struct MockProductIdentificationService: ProductIdentificationService {
    func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification {
        guard !photos.isEmpty else { throw ServiceError.invalid("Add at least one photo.") }
        try await Task.sleep(for: .milliseconds(350))
        // Deliberately deterministic fixture, not image recognition.
        return ProductIdentification(product: ProductMatch(title: "DEWALT 20V MAX XR Impact Driver", brand: "DEWALT", model: "DCF887B", category: "Tools"), subcategory: "Power tools", color: "Yellow / black", detectedCondition: .good, possibleModelNumber: "DCF887B", confidenceScore: photos.count >= 3 ? 0.94 : 0.58, alternateMatches: [ProductMatch(title: "Cordless drill", brand: "Unknown", model: "", category: "Tools"), ProductMatch(title: "Accent chair", brand: "Unknown", model: "", category: "Furniture"), ProductMatch(title: "Camping tent", brand: "Unknown", model: "", category: "Camping equipment")], recognizedAttributes: ["Power": "20V", "Type": "Tool only (verify)"])
    }
}
struct MockMarketResearchService: MarketResearchService {
    func research(item: SellItem) async throws -> [MarketComparable] {
        let base: Double = item.category == "Furniture" ? 150 : item.category == "Camping equipment" ? 70 : 96
        let sold = [0.85, 0.90, 0.94, 0.98, 1.0, 1.02, 1.06, 1.10, 1.125]
        let asking = (0..<14).map { 1.02 + Double($0) * 0.022 }
        return (sold.enumerated().map { index, ratio in
            MarketComparable(title: item.title, marketplace: index.isMultiple(of: 2) ? .ebay : .facebook, price: (base * ratio).rounded(), status: .sold, condition: item.condition, date: Date().addingTimeInterval(-Double(index + 1) * 86400))
        } + asking.enumerated().map { index, ratio in
            MarketComparable(title: item.title, marketplace: index.isMultiple(of: 2) ? .mercari : .facebook, price: (base * ratio).rounded(), status: .active, condition: item.condition, date: Date().addingTimeInterval(-Double(index) * 86400))
        })
    }
}
struct MockPricingAnalysisService: PricingAnalysisService {
    func analyze(item: SellItem, comparables: [MarketComparable]) async throws -> PricingRecommendation {
        let sold = comparables.filter { $0.status == .sold }.map(\.price).sorted()
        let asking = comparables.filter { $0.status == .active }.map(\.price).sorted()
        guard !sold.isEmpty, !asking.isEmpty else { throw ServiceError.invalid("Both sold and asking comparables are needed.") }
        func median(_ values: [Double]) -> Double { let i = values.count / 2; return values.count.isMultiple(of: 2) ? (values[i-1] + values[i]) / 2 : values[i] }
        let mid = median(sold)
        return PricingRecommendation(sellFastPrice: (mid * 0.875).rounded(), recommendedPrice: (mid * 1.03).rounded(), maximizeReturnPrice: (mid * 1.24).rounded(), soldMedian: mid, askingMedian: median(asking), soldLow: sold.first!, soldHigh: sold.last!, confidence: 0.8, rationale: "Suggested asking prices balance comparable sales with active competition. Higher prices may take longer; no outcome is guaranteed.", dataSourceSummary: "Simulated fixtures: \(sold.count) sold and \(asking.count) active. No live marketplace data.")
    }
}
struct MockMarketplaceRecommendationService: MarketplaceRecommendationService {
    func recommend(item: SellItem) async throws -> [MarketplaceRecommendation] {
        let local = ["Furniture", "Household items", "Baby gear", "Décor"].contains(item.category)
        let order: [Marketplace] = local ? [.facebook, .craigslist, .ebay, .mercari] : [.ebay, .facebook, .mercari, .craigslist]
        return order.enumerated().map { index, market in
            let pickup = market == .facebook || market == .craigslist
            return MarketplaceRecommendation(marketplace: market, fitScore: 0.94 - Double(index) * 0.12, rank: index + 1, estimatedDemand: "Simulated category fit", shippingFit: pickup ? "Suitable for local pickup" : "Confirm packaging and shipping costs", sellerFeeConsideration: pickup ? "Review any applicable selling fees" : "Selling fees may reduce proceeds; verify current fees", rationale: [pickup ? "Local buyers can inspect the item" : "Broad audience for this category", local && pickup ? "Avoid shipping a bulky item" : "Likely fit for \(item.category.lowercased())"])
        }
    }
}
struct MockPhotoEnhancementService: PhotoEnhancementService {
    func preview(photo: SellItemPhoto, style: EnhancementStyle) async throws -> PhotoEnhancement { PhotoEnhancement(style: style) }
}
struct MockListingGenerationService: ListingGenerationService {
    func generate(item: SellItem, marketplace: Marketplace) async throws -> ListingDraft {
        let details = [item.conditionNotes, item.sellerNotes].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        let name = item.title
        let description: String
        let shipping: String
        let pickup: String
        switch marketplace {
        case .ebay:
            description = "\(name)\nBrand: \(item.brand.isEmpty ? "Unspecified" : item.brand)\nModel: \(item.model.isEmpty ? "Unspecified" : item.model)\nCondition: \(item.condition.rawValue).\n\(details)\nPlease review all photos for visible wear and included accessories."
            shipping = "Confirm packed weight, dimensions, shipping cost, and handling time before posting."; pickup = ""
        case .facebook, .craigslist:
            description = "Selling my \(name). Condition: \(item.condition.rawValue.lowercased()).\n\(details)\nAsking \(item.askingPrice.formatted(.currency(code: "USD"))). Reasonable offers welcome. Message with questions."
            shipping = ""; pickup = "Local pickup; arrange details with the seller."
        case .mercari:
            description = "\(name) • \(item.condition.rawValue)\n\(details)\nSee photos for condition and included items."
            shipping = "Choose a shipping method after weighing the packaged item."; pickup = ""
        default:
            description = "\(marketplace.rawValue) listing: \(name)\nCondition: \(item.condition.rawValue).\n\(details)\nReview photos and ask about any details before buying."
            shipping = "Verify this marketplace supports this item and your delivery method."; pickup = ""
        }
        return ListingDraft(marketplace: marketplace, title: marketplace == .ebay ? String("\(name) \(item.model) \(item.condition.rawValue)".prefix(80)) : name, description: description, price: item.askingPrice, condition: item.condition, category: item.category, keywords: [item.brand, item.model, item.category].filter { !$0.isEmpty }, itemSpecifics: ["Brand": item.brand, "Model": item.model, "Color": item.color], shippingNotes: shipping, localPickupNotes: pickup, photoOrder: item.orderedPhotos.map(\.id))
    }
}
struct MockMarketplacePublishingService: MarketplacePublishingService {
    func validateListing(_ listing: ListingDraft) throws {
        guard !listing.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !listing.description.isEmpty, listing.price > 0, listing.price.isFinite, !listing.photoOrder.isEmpty else { throw ServiceError.invalid("Add a title, description, positive price, and at least one photo.") }
    }
    func prepareListing(_ listing: ListingDraft, item: SellItem) async throws -> PreparedListing {
        try validateListing(listing)
        let photos = listing.photoOrder.compactMap { id in item.photos.first { $0.id == id } }
        guard photos.count == listing.photoOrder.count else { throw ServiceError.invalid("A listing photo is missing. Review the photo order.") }
        return PreparedListing(draft: listing, photos: photos)
    }
    func publishListing(_ listing: ListingDraft) async throws -> PublishingReceipt { try validateListing(listing); return PublishingReceipt(reference: "MOCK-\(UUID().uuidString)", isMock: true) }
    func updateListing(_ listing: ListingDraft) async throws { try validateListing(listing) }
    func markSold(_ listing: ListingDraft, price: Double) async throws { guard price >= 0, price.isFinite else { throw ServiceError.invalid("Enter a valid sold price.") } }
    func delist(_ listing: ListingDraft) async throws { }
}
