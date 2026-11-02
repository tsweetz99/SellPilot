#if DEBUG
import Foundation

/// Debug-only sample data for the App Store screenshots. It exists only when the app is launched with `--screenshot-demo`
/// (together with `--ui-testing`, so it uses a throwaway store) and reads the seller's own demo photos from the folder named
/// by `SELLPILOT_DEMO_PHOTOS`. Release builds do not contain any of this.
@MainActor enum ScreenshotDemo {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--screenshot-demo") }
    private static var photoFolder: URL? { ProcessInfo.processInfo.environment["SELLPILOT_DEMO_PHOTOS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    private static func photos(_ names: [String]) -> [SellItemPhoto] {
        guard let folder = photoFolder else { return [] }
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).jpg")), let preview = PhotoImport.normalized(data) else { return nil }
            return try? SellItemPhoto(originalData: data, previewData: preview)
        }
    }

    /// Saves the sample items oldest first, so the newest (the skates) leads the Home list.
    static func seed(_ store: ItemStore) {
        guard enabled, store.items.isEmpty else { return }
        BackupService.lastBackup = Date()   // no backup reminder card on Home
        AIConsent.given = true              // Settings shows the AI switch on
        // Settings shows "Connect eBay account" instead of "setup unavailable" (these are made-up values, never sent anywhere).
        if let identity = try? JSONEncoder().encode(EbayDeployment.Identity(appID: "SellPilot-Demo-PRD-000000000-00000000", ruName: "SellPilot-Demo")) { UserDefaults.standard.set(identity, forKey: EbayDeployment.cacheKey) }
        store.save(book()); store.save(lights()); store.save(skates())
    }

    /// The book lookup the screenshots use, so the ISBN screen shows a found title without any network call.
    struct BookCatalog: BookCatalogService {
        func lookup(isbn: String) async throws -> BookDetails? {
            BookDetails(isbn: isbn, title: "Sovereignty: The Battle for the Hearts and Minds of Men", authors: ["Ryan Michler"], publisher: "Lifestyle Entrepreneurs Press", year: nil)
        }
    }

    private static func book() -> SellItem {
        var item = SellItem()
        item.createdAt = Date().addingTimeInterval(-3 * 86400)
        item.photos = photos(["book-1", "book-2", "book-3"]); item.coverPhotoID = item.photos.first?.id
        let isbn = "9781946697899"
        item.isbn = isbn
        item.bookDetails = BookDetails(isbn: isbn, title: "Sovereignty: The Battle for the Hearts and Minds of Men", authors: ["Ryan Michler"], publisher: "Lifestyle Entrepreneurs Press", year: nil)
        item.title = item.bookDetails?.listingTitle ?? "Sovereignty"
        item.brand = "Lifestyle Entrepreneurs Press"; item.category = "Books"; item.subcategory = "Hardcover"; item.color = "Red"
        item.condition = .excellent; item.confidenceScore = 0.97
        item.identification = ProductIdentification(product: ProductMatch(title: item.title, brand: item.brand, model: "", category: "Books"), subcategory: "Hardcover", color: "Red", detectedCondition: .excellent, possibleModelNumber: nil, confidenceScore: 0.97, alternateMatches: [], recognizedAttributes: ["Format": "Hardcover with dust jacket"], provider: "SellPilot AI")
        item.status = .draft; item.workflowStep = 1
        item.selectedMarketplaces = [.ebay, .facebook]
        return item
    }

    private static func lights() -> SellItem {
        var item = SellItem()
        item.createdAt = Date().addingTimeInterval(-2 * 86400)
        item.photos = photos(["lights-1"]); item.coverPhotoID = item.photos.first?.id
        item.title = "GE String-A-Long 100 Miniature Lights, Green Wire"; item.brand = "GE"; item.model = "1295942"; item.category = "Household items"; item.subcategory = "Holiday lighting"; item.color = "Green"
        item.condition = .new; item.status = .active; item.askingPrice = 12; item.selectedMarketplace = .facebook; item.selectedMarketplaces = [.facebook]
        item.workflowStep = SellItem.lastStep
        return item
    }

    private static func skates() -> SellItem {
        var item = SellItem()
        item.createdAt = Date().addingTimeInterval(-86400)
        item.photos = photos(["skates-1", "skates-2", "skates-3", "skates-4", "skates-5", "skates-6"]); item.coverPhotoID = item.photos.first?.id
        item.title = "Crazy Skates Glam Roller Skates, Teal Glitter"; item.brand = "Crazy Skates"; item.model = "Glam"
        item.category = "Sporting goods"; item.subcategory = "Roller skates"; item.color = "Teal glitter"
        item.condition = .excellent; item.confidenceScore = 0.94
        item.sellerNotes = "Comes with the original box and the carry bag."
        item.identification = ProductIdentification(product: ProductMatch(title: item.title, brand: item.brand, model: item.model, category: item.category), subcategory: item.subcategory, color: item.color, detectedCondition: .excellent, possibleModelNumber: "Glam", confidenceScore: 0.94,
            alternateMatches: [ProductMatch(title: "Crazy Skates Disco Glam Roller Skates", brand: "Crazy Skates", model: "Disco Glam", category: "Sporting goods"), ProductMatch(title: "Retro quad roller skates, glitter", brand: "Unknown", model: "", category: "Sporting goods")],
            recognizedAttributes: ["Style": "Quad roller skates", "Closure": "Lace-up"], provider: "SellPilot AI")
        item.status = .ready; item.selectedMarketplace = .ebay; item.selectedMarketplaces = [.ebay, .facebook]
        item.pricingStrategy = .recommended; item.askingPrice = 64
        item.pricing = PricingRecommendation(sellFastPrice: 54, recommendedPrice: 64, maximizeReturnPrice: 78, soldMedian: 61, askingMedian: 72, soldLow: 46, soldHigh: 88, confidence: 0.8,
            rationale: "Suggested asking prices balance similar active listings with your item's condition. Higher prices may take longer, and no outcome is guaranteed.",
            dataSourceSummary: "Based on 12 similar active eBay listings; median asking $72. Sale-price estimates assume sales close about 15% below asking; sold prices are not observed.", marketplace: .ebay, source: "ebay-browse-active")
        let asking: [Double] = [49, 55, 58, 62, 65, 68, 72, 75, 79, 84, 88, 95]
        item.comparables = asking.enumerated().map { i, price in MarketComparable(title: "Crazy Skates Glam roller skates, teal glitter", marketplace: .ebay, price: price, status: .active, condition: i < 4 ? .good : .excellent, date: Date().addingTimeInterval(-Double(i) * 86400)) }
        item.recommendations = [
            MarketplaceRecommendation(marketplace: .ebay, fitScore: 0.94, rank: 1, estimatedDemand: "Broad audience", shippingFit: "Confirm packaging and shipping costs", sellerFeeConsideration: "Selling fees may reduce proceeds; verify current fees", rationale: ["Broad audience for this category", "Likely fit for sporting goods"]),
            MarketplaceRecommendation(marketplace: .facebook, fitScore: 0.82, rank: 2, estimatedDemand: "Local buyers", shippingFit: "Suitable for local pickup", sellerFeeConsideration: "Review any applicable selling fees", rationale: ["Local buyers can inspect the item", "Likely fit for sporting goods"]),
        ]
        let photoIDs = item.orderedPhotos.map(\.id)
        item.listings = [
            ListingDraft(marketplace: .ebay, title: "Crazy Skates Glam Roller Skates Teal Glitter Retro Quad with Box", description: "Crazy Skates Glam roller skates in teal glitter with white soles and cream wheels.\n\nCondition: Excellent.\nComes with the original box and the carry bag.\n\nPlease review all photos for the details of the item you will receive.", price: 64, condition: .excellent, category: "Sporting goods", keywords: ["Crazy Skates", "Glam", "roller skates"], itemSpecifics: ["Brand": "Crazy Skates", "Model": "Glam", "Color": "Teal glitter"], shippingNotes: "Ships in the original box. Confirm packed weight and shipping cost before posting.", localPickupNotes: "", photoOrder: photoIDs, preparedAt: nil, mockPublishReference: nil),
            ListingDraft(marketplace: .facebook, title: "Crazy Skates Glam Roller Skates, Teal Glitter", description: "Selling my Crazy Skates Glam roller skates in teal glitter. Excellent condition, with the original box and carry bag. Asking $64. Reasonable offers welcome. Message with questions.", price: 64, condition: .excellent, category: "Sporting goods", keywords: ["Crazy Skates", "Glam"], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "Local pickup; arrange details with the seller.", photoOrder: photoIDs, preparedAt: nil, mockPublishReference: nil),
        ]
        item.workflowStep = SellItem.lastStep
        return item
    }
}
#endif
