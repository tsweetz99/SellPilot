import Foundation
protocol ProductIdentificationService { func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification }
protocol MarketResearchService { func research(item: SellItem) async throws -> [MarketComparable] }
protocol PricingAnalysisService { func analyze(item: SellItem, comparables: [MarketComparable]) async throws -> PricingRecommendation }
protocol MarketplaceRecommendationService { func recommend(item: SellItem) async throws -> [MarketplaceRecommendation] }
protocol PhotoEnhancementService { func preview(photo: SellItemPhoto, style: EnhancementStyle) async throws -> PhotoEnhancement }
protocol ListingGenerationService { func generate(item: SellItem, marketplace: Marketplace) async throws -> ListingDraft }
struct PreparedListing { var draft: ListingDraft; var photos: [SellItemPhoto] }
struct PublishingReceipt { var reference: String; var isMock: Bool }
protocol MarketplacePublishingService {
    func validateListing(_ listing: ListingDraft) throws
    func prepareListing(_ listing: ListingDraft, item: SellItem) async throws -> PreparedListing
    func publishListing(_ listing: ListingDraft) async throws -> PublishingReceipt
    func updateListing(_ listing: ListingDraft) async throws
    func markSold(_ listing: ListingDraft, price: Double) async throws
    func delist(_ listing: ListingDraft) async throws
}
enum ServiceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}
struct AppServices {
    var identification: any ProductIdentificationService = MockProductIdentificationService()
    var research: any MarketResearchService = MockMarketResearchService()
    var pricing: any PricingAnalysisService = MockPricingAnalysisService()
    var marketplaces: any MarketplaceRecommendationService = MockMarketplaceRecommendationService()
    var enhancement: any PhotoEnhancementService = MockPhotoEnhancementService()
    var listings: any ListingGenerationService = MockListingGenerationService()
    var publishing: any MarketplacePublishingService = MockMarketplacePublishingService()
}
