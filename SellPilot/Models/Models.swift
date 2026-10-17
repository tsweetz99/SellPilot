import Foundation

enum ItemStatus: String, Codable, CaseIterable { case draft = "Draft", ready = "Ready", active = "Active", sold = "Sold", archived = "Archived" }
enum ItemCondition: String, Codable, CaseIterable { case new = "New", excellent = "Excellent", good = "Good", fair = "Fair", parts = "For parts" }
enum Marketplace: String, Codable, CaseIterable, Identifiable {
    case ebay = "eBay", facebook = "Facebook Marketplace", mercari = "Mercari", poshmark = "Poshmark", etsy = "Etsy", depop = "Depop", craigslist = "Craigslist", tiktok = "TikTok Shop", pinterest = "Pinterest", other = "Other"
    var id: String { rawValue }
}
enum PricingStrategy: String, Codable, CaseIterable { case fast = "Sell Fast", recommended = "Recommended", maximize = "Maximize Return" }
enum EnhancementStyle: String, Codable, CaseIterable { case original = "Original", clean = "Clean Marketplace", studio = "Studio", lifestyle = "Lifestyle" }
struct PhotoEnhancement: Codable, Equatable { var style: EnhancementStyle = .original; var simulated = true; var previewData: Data? = nil; var integrityPolicy = "Better photos. Same product. Originals are always preserved." }
/// Photo metadata only. Image bytes live as files in `PhotoStorage`, so saving an item no longer re-encodes every photo.
struct SellItemPhoto: Codable, Equatable, Identifiable {
    var id = UUID()
    var enhancement = PhotoEnhancement()

    /// Writes the original (and optional display preview) to disk. Throws if the bytes cannot be stored.
    init(originalData: Data, previewData: Data? = nil) throws {
        try PhotoStorage.shared.write(originalData, id: id, kind: .original)
        if let previewData { try PhotoStorage.shared.write(previewData, id: id, kind: .preview) }
    }

    /// Original bytes, read from disk on demand. Empty if the file is missing.
    var originalData: Data { PhotoStorage.shared.read(id: id, kind: .original) ?? Data() }
    var previewData: Data? { PhotoStorage.shared.read(id: id, kind: .preview) }
    var originalByteCount: Int { PhotoStorage.shared.byteCount(id: id, kind: .original) }
    var isAvailable: Bool { PhotoStorage.shared.exists(id: id, kind: .original) }

    private enum CodingKeys: String, CodingKey { case id, enhancement, originalData, previewData }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        enhancement = try container.decodeIfPresent(PhotoEnhancement.self, forKey: .enhancement) ?? PhotoEnhancement()
        // Items saved before photo files existed carry their bytes inline. Move them to disk; a failed write throws
        // so the stored payload is never replaced by a version that lost its photos.
        if let legacyOriginal = try container.decodeIfPresent(Data.self, forKey: .originalData) {
            try PhotoStorage.shared.write(legacyOriginal, id: id, kind: .original)
            if let legacyPreview = try container.decodeIfPresent(Data.self, forKey: .previewData) {
                try PhotoStorage.shared.write(legacyPreview, id: id, kind: .preview)
            }
            (decoder.userInfo[.photoMigration] as? PhotoMigrationTracker)?.count += 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(enhancement, forKey: .enhancement)
    }
}
struct ProductMatch: Codable, Equatable, Identifiable { var id = UUID(); var title: String; var brand: String; var model: String; var category: String }
struct ProductIdentification: Codable, Equatable {
    var product: ProductMatch
    var subcategory: String
    var color: String
    var detectedCondition: ItemCondition
    var possibleModelNumber: String?
    var confidenceScore: Double
    var alternateMatches: [ProductMatch]
    var recognizedAttributes: [String: String]
    /// nil for the built-in demo fixture; otherwise names the model/provider that produced the result.
    var provider: String? = nil
    var isSimulated: Bool { provider == nil }
}
enum ComparableStatus: String, Codable { case active = "Active asking", sold = "Sold comparable" }
struct MarketComparable: Codable, Equatable, Identifiable {
    var id = UUID(); var title: String; var marketplace: Marketplace; var price: Double; var status: ComparableStatus; var condition: ItemCondition; var date: Date
    var url: URL? = nil
    /// true when an AI check confirmed this listing is the same product and configuration as the seller's item.
    var verifiedMatch: Bool? = nil
}
struct PricingRecommendation: Codable, Equatable {
    var sellFastPrice: Double; var recommendedPrice: Double; var maximizeReturnPrice: Double
    var soldMedian: Double; var askingMedian: Double; var soldLow: Double; var soldHigh: Double
    var confidence: Double; var rationale: String; var dataSourceSummary: String
    var marketplace: Marketplace?
    /// nil for the built-in simulated fixtures; otherwise names the data source.
    var source: String? = nil
    func price(for strategy: PricingStrategy) -> Double {
        switch strategy { case .fast: sellFastPrice; case .recommended: recommendedPrice; case .maximize: maximizeReturnPrice }
    }
}
struct MarketplaceRecommendation: Codable, Equatable, Identifiable {
    var id: Marketplace { marketplace }
    var marketplace: Marketplace; var fitScore: Double; var rank: Int; var estimatedDemand: String; var shippingFit: String; var sellerFeeConsideration: String; var rationale: [String]
}
struct ListingDraft: Codable, Equatable, Identifiable {
    var id = UUID(); var marketplace: Marketplace; var title: String; var description: String; var price: Double; var condition: ItemCondition; var category: String; var keywords: [String]; var itemSpecifics: [String: String]; var shippingNotes: String; var localPickupNotes: String; var photoOrder: [UUID]; var preparedAt: Date?; var mockPublishReference: String?
    /// Set once eBay accepts the listing. `ebayEnvironment` is "sandbox" for test listings.
    var ebayCategoryID: String? = nil; var ebayCategoryName: String? = nil; var ebayRequiredSpecifics: [String]? = nil
    var ebayOfferID: String? = nil; var ebayListingID: String? = nil; var ebayListingURL: URL? = nil; var ebayEnvironment: String? = nil
    /// The seller's chosen business policies for this listing; the first of each is used when unset.
    var ebayFulfillmentPolicyID: String? = nil; var ebayPaymentPolicyID: String? = nil; var ebayReturnPolicyID: String? = nil
    var fullText: String { "\(title)\n\(price.formatted(.currency(code: "USD")))\n\(condition.rawValue)\n\n\(description)\n\n\(shippingNotes)\n\(localPickupNotes)" }
}
struct SellItem: Codable, Equatable, Identifiable {
    var id = UUID(); var createdAt = Date(); var updatedAt = Date()
    var title = "Untitled item"; var brand = ""; var model = ""; var category = "Household items"; var subcategory = ""; var color = ""
    var condition: ItemCondition = .good; var conditionNotes = ""; var sellerNotes = ""; var confidenceScore = 0.0
    var status: ItemStatus = .draft; var selectedMarketplace: Marketplace = .facebook; var selectedMarketplaces: [Marketplace] = [.facebook, .ebay]
    var pricingStrategy: PricingStrategy = .recommended; var askingPrice = 0.0; var soldPrice: Double?; var soldDate: Date?; var coverPhotoID: UUID?
    var photos: [SellItemPhoto] = []; var identification: ProductIdentification?; var comparables: [MarketComparable] = []; var pricing: PricingRecommendation?; var recommendations: [MarketplaceRecommendation] = []; var listings: [ListingDraft] = []
    var workflowStep = 0
    /// nil on items saved with the original 8-step flow; see `migratedStep`.
    var flowVersion: Int? = SellItem.currentFlowVersion
    static let currentFlowVersion = 2
    /// Steps: 0 Photograph, 1 Confirm (details + notes), 2 Price & places, 3 Ready.
    static let lastStep = 3
    /// Maps a step number from the original 8-step flow (photograph, confirm, notes, market, price, places, photos, ready).
    static func migratedStep(fromV1 step: Int) -> Int { [0, 1, 1, 2, 2, 2, 2, 3][min(max(step, 0), 7)] }
    static let categories = ["Tools", "Furniture", "Electronics", "Sporting goods", "Camping equipment", "Collectibles", "Household items", "Baby gear", "Décor", "Automotive accessories", "Hobby equipment", "Other"]
    var orderedPhotos: [SellItemPhoto] {
        guard let coverPhotoID, let cover = photos.first(where: { $0.id == coverPhotoID }) else { return photos }
        return [cover] + photos.filter { $0.id != coverPhotoID }
    }
}
