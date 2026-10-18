import Foundation
import Observation
@MainActor @Observable final class SellingWorkflow {
    var item: SellItem
    var busy = false
    var error: String?
    var notice: String?
    /// Set when automatic identification failed, so the capture screen can offer manual entry.
    var identificationFailed = false
    /// eBay category suggestions and the chosen category's item specifics, used by the publish card.
    var ebayCategoryChoices: [EbayCategory] = []
    var ebayAspects: [EbayAspect] = []
    var ebayPolicies = EbaySellerPolicies()
    /// Why the seller's policies could not be loaded, shown under the policy menus instead of an endless "Loading…".
    var ebayPoliciesProblem: String?
    /// One line about the book lookup (found, not found, invalid ISBN), shown next to the ISBN field.
    var isbnStatus: String?
    /// True when the last eBay failure means the seller must sign in again; the alert then offers to open Settings.
    var reconnectNeeded = false
    /// Rebuilt after the seller reconnects eBay in Settings, so a fresh sign-in is picked up without reopening the item.
    var services: AppServices
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
                applyBookDetails()
            case 1:
                guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.invalid("Enter a product name.") }
                guard !item.listings.contains(where: { $0.ebayListingID != nil }) else { throw ServiceError.invalid("This item has a live eBay listing. End it before changing the item or its price.") }
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
                guard !item.listings.contains(where: { $0.ebayListingID != nil }) else { throw ServiceError.invalid("This item has a live eBay listing. End it before generating new listings.") }
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
    /// Existing data is kept if the refresh fails. The item returns to Price & places; its listings are left as they are
    /// (they still show the old price) and are regenerated when the seller continues, so the Ready screen never loses
    /// the listing it is displaying mid-update.
    func refreshMarketPrices() async {
        guard !busy, item.status == .draft || item.status == .ready, item.workflowStep >= 2 else { return }
        guard !item.listings.contains(where: { $0.ebayListingID != nil }) else { self.error = "End the eBay listing before changing the price, so it isn't left live at the old price."; return }
        busy = true; defer { busy = false }
        do {
            let comparables = try await services.research.research(item: item)
            let pricing = try await services.pricing.analyze(item: item, comparables: comparables)
            if item.recommendations.isEmpty { item.recommendations = try await services.marketplaces.recommend(item: item) }
            item.comparables = comparables; item.pricing = pricing
            item.askingPrice = pricing.price(for: item.pricingStrategy)
            item.status = .draft; item.workflowStep = 2
            save()
        } catch { self.error = "Couldn't refresh market prices: \(error.localizedDescription) Your saved prices were kept." }
    }

    // MARK: eBay publishing

    private func report(_ failure: Error) { error = failure.localizedDescription; reconnectNeeded = failure is EbayAuthError }

    @MainActor func reloadServices() { services = AppServices.make() }

    /// Suggests an eBay category and pre-fills its required item specifics from what we know (and facts Claude extracts from the seller's own description, when configured).
    func prepareEbayListing(_ index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index), !busy else { return }
        busy = true; defer { busy = false }
        do {
            let choices = try await ebay.suggestCategories(query: item.title)
            guard let first = choices.first else { throw ServiceError.invalid("eBay found no category for this item. Try a clearer product name.") }
            ebayCategoryChoices = choices
            try await applyEbayCategory(first, index: index, using: ebay)
        } catch { report(error) }
    }

    func chooseEbayCategory(_ category: EbayCategory, index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index), !busy else { return }
        busy = true; defer { busy = false }
        do { try await applyEbayCategory(category, index: index, using: ebay) } catch { report(error) }
    }

    /// Reloads the allowed item specifics for a draft whose category was already chosen (after reopening the app).
    func loadEbayAspects(_ index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index), let id = item.listings[index].ebayCategoryID, ebayAspects.isEmpty else { return }
        ebayAspects = (try? await ebay.aspects(for: id)) ?? []
    }

    /// Loads the seller's business policies and, if none is chosen yet, selects the first of each so the seller can see and change them.
    func loadEbayPolicies(_ index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index) else { return }
        let loaded: EbaySellerPolicies
        do { loaded = try await ebay.policies() } catch { ebayPoliciesProblem = error.localizedDescription; return }
        ebayPoliciesProblem = loaded.fulfillment.isEmpty || loaded.payment.isEmpty || loaded.returns.isEmpty
            ? "eBay returned no \([loaded.fulfillment.isEmpty ? "shipping" : nil, loaded.payment.isEmpty ? "payment" : nil, loaded.returns.isEmpty ? "return" : nil].compactMap { $0 }.joined(separator: ", ")) policy for this account. Create it in Seller Hub (Account > Business policies), then reload."
            : nil
        ebayPolicies = loaded
        func keep(_ chosen: String?, in list: [EbayPolicy]) -> String? { chosen.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list.first?.id }
        item.listings[index].ebayFulfillmentPolicyID = keep(item.listings[index].ebayFulfillmentPolicyID, in: loaded.fulfillment)
        item.listings[index].ebayPaymentPolicyID = keep(item.listings[index].ebayPaymentPolicyID, in: loaded.payment)
        item.listings[index].ebayReturnPolicyID = keep(item.listings[index].ebayReturnPolicyID, in: loaded.returns)
        save()
    }

    private func applyEbayCategory(_ category: EbayCategory, index: Int, using ebay: any EbayListingService) async throws {
        let aspects = try await ebay.aspects(for: category.id)
        var specifics = EbaySpecifics.prefill(item: item, existing: item.listings[index].itemSpecifics, aspects: aspects)
        // Claude only sees the seller's own description; matching to eBay's names and allowed values happens here, on the device.
        let facts = (try? await services.specifics?.facts(for: item)) ?? [:]
        specifics = EbaySpecifics.fill(aspects: aspects, existing: specifics, facts: facts, item: item)
        ebayAspects = aspects
        item.listings[index].ebayCategoryID = category.id; item.listings[index].ebayCategoryName = category.path
        item.listings[index].ebayRequiredSpecifics = aspects.filter(\.required).map(\.name)
        item.listings[index].itemSpecifics = specifics; item.listings[index].category = category.name
        save()
    }

    /// Creates the listing on eBay. Real (non-sandbox) listings also mark the item Active; sandbox test listings never do.
    func publishToEbay(_ index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index), !busy else { return }
        busy = true; defer { busy = false }
        do {
            var draft = item.listings[index]
            guard draft.ebayListingID == nil else { throw ServiceError.invalid("This listing is already on eBay.") }
            guard let categoryID = draft.ebayCategoryID else { throw ServiceError.invalid("Choose an eBay category first.") }
            if ebayAspects.isEmpty { ebayAspects = try await ebay.aspects(for: categoryID) }
            let missing = EbaySpecifics.missing(ebayAspects, in: draft.itemSpecifics)
            guard missing.isEmpty else { throw ServiceError.invalid("Fill in the required eBay details first: \(missing.joined(separator: ", ")).") }
            let known = Set(ebayAspects.map { $0.name.lowercased() })
            draft.itemSpecifics = draft.itemSpecifics.filter { known.contains($0.key.lowercased()) }
            try services.publishing.validateListing(draft)
            let prepared = try await services.publishing.prepareListing(draft, item: item)
            let result = try await ebay.publish(draft: draft, photos: prepared.photos, conditionNotes: item.conditionNotes)
            item.listings[index].ebayOfferID = result.offerID; item.listings[index].ebayListingID = result.listingID
            item.listings[index].ebayListingURL = result.url; item.listings[index].ebayEnvironment = ebay.environment.rawValue
            if ebay.environment == .production { item.status = .active }
            save()
            notice = ebay.environment == .sandbox ? "Test listing created in the eBay Sandbox. Nothing was posted to real eBay." : "Your listing is live on eBay."
        } catch { report(error) }
    }

    func endEbayListing(_ index: Int) async {
        guard let ebay = services.ebay, item.listings.indices.contains(index), let offerID = item.listings[index].ebayOfferID, !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await ebay.withdraw(offerID: offerID)
            item.listings[index].ebayListingID = nil; item.listings[index].ebayListingURL = nil
            save(); notice = "The eBay listing was ended."
        } catch { report(error) }
    }

    /// Looks for an ISBN barcode in a newly added photo. Runs on the device; the first barcode found wins.
    func scanForISBN(in photoData: Data) async {
        guard item.isbn == nil, let isbn = await BarcodeReader.isbn(in: photoData), item.isbn == nil else { return }
        await setISBN(isbn)
    }

    /// For an ISBN the seller typed in. Says so when it is not a valid ISBN.
    func lookUpISBN(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { item.isbn = nil; item.bookDetails = nil; isbnStatus = nil; save(); return }
        guard let isbn = ISBN.normalize(trimmed) else { isbnStatus = "That isn't a valid ISBN. Check the digits on the back cover."; return }
        await setISBN(isbn)
    }

    private func setISBN(_ isbn: String) async {
        item.isbn = isbn; item.bookDetails = nil; isbnStatus = "ISBN \(isbn)"
        if let books = services.books {
            do {
                if let details = try await books.lookup(isbn: isbn) { item.bookDetails = details; isbnStatus = "ISBN \(isbn) · \(details.listingTitle)"; applyBookDetails() }
                else { isbnStatus = "ISBN \(isbn) · not in the book catalog. Fill in the details yourself." }
            } catch { isbnStatus = "ISBN \(isbn) · couldn't reach the book catalog. Fill in the details yourself." }
        }
        save()
    }

    /// The catalog's title and publisher are exact, so they replace the photo-based guess; condition and color stay from the photos.
    func applyBookDetails() {
        guard let details = item.bookDetails else { return }
        item.title = details.listingTitle; item.category = "Books"
        if let publisher = details.publisher { item.brand = publisher }
        item.model = ""
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
