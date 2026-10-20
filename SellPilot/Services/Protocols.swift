import Foundation
protocol ProductIdentificationService {
    /// Shown to the user when photos leave the device; nil for on-device/demo implementations.
    var disclosure: String? { get }
    func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification
}
extension ProductIdentificationService { var disclosure: String? { nil } }
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
/// Where eBay publishing stands, so the screen can say what is missing instead of hiding the whole section.
enum EbayPublishingSetup: Equatable { case notConfigured, needsSignIn, ready }

struct AppServices {
    var identification: any ProductIdentificationService = MockProductIdentificationService()
    var research: any MarketResearchService = MockMarketResearchService()
    var pricing: any PricingAnalysisService = MockPricingAnalysisService()
    var marketplaces: any MarketplaceRecommendationService = MockMarketplaceRecommendationService()
    var enhancement: any PhotoEnhancementService = MockPhotoEnhancementService()
    var listings: any ListingGenerationService = MockListingGenerationService()
    var publishing: any MarketplacePublishingService = MockMarketplacePublishingService()
    /// Real eBay publishing (sandbox for now); nil until sandbox keys and a user token are configured.
    var ebay: (any EbayListingService)? = nil
    var specifics: (any ItemSpecificsService)? = nil
    /// Book facts from an ISBN; nil in UI tests.
    var books: (any BookCatalogService)? = nil
    /// eBay is set up enough to connect, but no seller is signed in (and no test token is saved).
    var ebayNeedsSignIn = false
    /// True when live publishing is switched on, so screens name the real eBay instead of the sandbox.
    var ebayIsLive = false
    var ebaySetup: EbayPublishingSetup { ebay != nil ? .ready : (ebayNeedsSignIn ? .needsSignIn : .notConfigured) }
}
extension AppServices {
    var usesLiveIdentification: Bool { identification.disclosure != nil }
    var usesLivePricing: Bool { !(research is MockMarketResearchService) }
    /// Real identification when an API key is configured; otherwise the demo fixture. UI tests always get the fixture.
    @MainActor static func make() -> AppServices {
        var services = AppServices()
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        // A key the seller entered themselves wins; otherwise the studio's hosted AI service. UI tests always get the demo fixture.
        if !testing {
            if let key = APIKeyStore.load() { services.identification = ClaudeIdentificationService(configuration: .init(apiKey: key)) }
            else { services.identification = HostedIdentificationService() }
        }
        if !testing { services.books = PublicBookCatalog() }
        // With a token server configured, eBay application tokens come from it (the Cert ID can then stay off the device).
        // A Cert ID still saved on the device is used as a fallback, so the switch never leaves a gap.
        let server = APIKeyStore.load(.ebayAuthProxy).flatMap(URL.init(string:))
        func appTokens(_ environment: EbaySellEnvironment, direct: EbayCredentials?) -> (any EbayAppTokenSource)? {
            let local = direct.map { EbayTokenProvider(credentials: $0, baseURL: environment.apiBase, session: .shared) }
            guard let server else { return local }
            return FallbackAppTokenSource(primary: ProxyAppTokenProvider(endpoint: server, environment: environment, installKey: APIKeyStore.installKey()), fallback: local)
        }
        if !testing, let tokens = appTokens(.production, direct: EbayCredentials.load()) {
            let ebay = EbayBrowseMarketResearchService(configuration: .init(credentials: EbayCredentials.load()), appTokens: tokens)
            services.research = FilteredMarketResearchService(base: ebay, filter: TitleComparableFilter())
            services.pricing = AskingPricePricingService()
        }
        let live = LiveSettings.enabled
        services.ebayIsLive = live
        let environment: EbaySellEnvironment = live ? .production : .sandbox
        let sandboxCredentials = APIKeyStore.load(.ebaySandboxAppID).flatMap { app in APIKeyStore.load(.ebaySandboxCertID).map { EbayCredentials(appID: app, certID: $0) } }
        let credentials = live ? EbayCredentials.load() : sandboxCredentials
        if !testing, let tokens = appTokens(environment, direct: credentials) {
            // A signed-in eBay connection wins. A pasted token is a testing shortcut for the sandbox only, never for real listings.
            let seller: (any EbayUserTokenSource)? = {
                if let connection = EbayConnections.make(environment), connection.isConnected { return connection }
                return live ? nil : APIKeyStore.load(.ebaySandboxUserToken).map { StaticEbayTokenSource(token: $0) }
            }()
            if let seller {
                var configuration = EbaySellConfiguration(environment: environment, credentials: credentials, tokens: seller)
                if live {
                    configuration.allowLivePublishing = true
                    configuration.locationPostalCode = LiveSettings.shipFromZip
                    configuration.locationKey = "SELLPILOT_\(LiveSettings.shipFromZip)"
                }
                services.ebay = EbaySellService(configuration: configuration, appTokens: tokens)
                if let key = APIKeyStore.load() { services.specifics = ClaudeItemFactsService(configuration: .init(apiKey: key)) }
                else { services.specifics = HostedItemFactsService() }
            } else if EbayConnections.make(environment) != nil {
                services.ebayNeedsSignIn = true   // everything is configured except the sign-in itself
            }
        }
        return services
    }
}
