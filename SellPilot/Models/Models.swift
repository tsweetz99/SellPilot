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
struct SellItemPhoto: Codable, Equatable, Identifiable {
    var id = UUID()
    var originalData: Data
    var previewData: Data? = nil
    var enhancement = PhotoEnhancement()
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
}
enum ComparableStatus: String, Codable { case active = "Active asking", sold = "Sold comparable" }
struct MarketComparable: Codable, Equatable, Identifiable {
    var id = UUID(); var title: String; var marketplace: Marketplace; var price: Double; var status: ComparableStatus; var condition: ItemCondition; var date: Date
}
struct PricingRecommendation: Codable, Equatable {
    var sellFastPrice: Double; var recommendedPrice: Double; var maximizeReturnPrice: Double
    var soldMedian: Double; var askingMedian: Double; var soldLow: Double; var soldHigh: Double
    var confidence: Double; var rationale: String; var dataSourceSummary: String
    var marketplace: Marketplace?
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
    var orderedPhotos: [SellItemPhoto] {
        guard let coverPhotoID, let cover = photos.first(where: { $0.id == coverPhotoID }) else { return photos }
        return [cover] + photos.filter { $0.id != coverPhotoID }
    }
}
