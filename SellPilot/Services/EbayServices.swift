import Foundation

struct EbayCredentials: Equatable {
    var appID: String
    var certID: String
    static func load() -> EbayCredentials? {
        guard let app = APIKeyStore.load(.ebayAppID), let cert = APIKeyStore.load(.ebayCertID) else { return nil }
        return EbayCredentials(appID: app, certID: cert)
    }
}

struct EbayConfiguration {
    /// nil when application tokens come from the token server instead of this device.
    var credentials: EbayCredentials?
    var baseURL = URL(string: "https://api.ebay.com")!
    var marketplaceID = "EBAY_US"
    var resultLimit = 50
    /// Below this many usable listings, a broader query is tried.
    var minimumListings = 5
}

/// Where application-level tokens (category lookup, comps) come from.
protocol EbayAppTokenSource {
    func accessToken(forceRefresh: Bool) async throws -> String
}
extension EbayAppTokenSource { func accessToken() async throws -> String { try await accessToken(forceRefresh: false) } }

/// Fetches and caches an application access token (client-credentials grant) using the Cert ID on this device.
actor EbayTokenProvider: EbayAppTokenSource {
    private let credentials: EbayCredentials
    private let baseURL: URL
    private let session: URLSession
    private var token: String?
    private var expiry = Date.distantPast
    init(credentials: EbayCredentials, baseURL: URL, session: URLSession) { self.credentials = credentials; self.baseURL = baseURL; self.session = session }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token, expiry > Date() { return token }
        var request = URLRequest(url: baseURL.appending(path: "identity/v1/oauth2/token"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Basic \(Data("\(credentials.appID):\(credentials.certID)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope".utf8)
        let (data, response) = try await EbayHTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw EbayHTTP.error(status: response.statusCode, body: data, whileAuthenticating: true) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = json["access_token"] as? String else {
            throw ServiceError.invalid("eBay returned an unreadable sign-in response.")
        }
        token = value
        expiry = Date().addingTimeInterval(max(60, ((json["expires_in"] as? Double) ?? 7200) - 120))
        return value
    }
}

/// Application tokens from your own token server, so the Cert ID never has to be on the device. Each install sends its own
/// random key; the server uses it to rate-limit installs separately (it is not a login).
actor ProxyAppTokenProvider: EbayAppTokenSource {
    private let endpoint: URL
    private let environment: EbaySellEnvironment
    private let installKey: String
    private let session: URLSession
    private let now: () -> Date
    private var token: String?
    private var expiry = Date.distantPast
    init(endpoint: URL, environment: EbaySellEnvironment, installKey: String, session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.endpoint = endpoint; self.environment = environment; self.installKey = installKey; self.session = session; self.now = now
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token, expiry > now() { return token }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installKey, forHTTPHeaderField: "X-SellPilot-Install")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["environment": environment.rawValue, "grant": "client_credentials"])
        let (data, response) = try await EbayHTTP.perform(request, session: session)
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(response.statusCode, data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = json["access_token"] as? String else {
            throw ServiceError.invalid("The token server returned an unreadable response.")
        }
        token = value
        expiry = now().addingTimeInterval(max(60, ((json["expires_in"] as? Double) ?? 7200) - 120))
        return value
    }

    static func failure(_ status: Int, _ body: Data) -> ServiceError {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
        switch (status, error) {
        case (_, "rate_limited"): return .invalid("Too many eBay token requests from this device. Try again in a while.")
        case (403, _): return .invalid("Your token server isn't set up to give out eBay app tokens yet.")
        case (401, "install_key_required"): return .invalid("The token server did not accept this app's install key.")
        case (503, _): return .invalid("The token server is temporarily unavailable.")
        case (404, _): return .invalid("The token server address looks wrong (not found).")
        default: return .invalid("The token server failed (\(status)).")
        }
    }
}

/// Tries the token server first and falls back to a Cert ID held on the device, so switching over never leaves a gap.
struct FallbackAppTokenSource: EbayAppTokenSource {
    var primary: any EbayAppTokenSource
    var fallback: (any EbayAppTokenSource)?
    func accessToken(forceRefresh: Bool) async throws -> String {
        do { return try await primary.accessToken(forceRefresh: forceRefresh) }
        catch { guard let fallback else { throw error }; return try await fallback.accessToken(forceRefresh: forceRefresh) }
    }
}

/// Used when neither a token server nor a Cert ID is configured.
struct MissingAppTokenSource: EbayAppTokenSource {
    func accessToken(forceRefresh: Bool) async throws -> String { throw ServiceError.invalid("eBay isn't set up in Settings yet.") }
}

enum EbayHTTP {
    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalid("Unexpected response from eBay.") }
            return (data, http)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: throw ServiceError.invalid("No internet connection.")
            case .timedOut: throw ServiceError.invalid("eBay took too long to respond.")
            default: throw ServiceError.invalid("Could not reach eBay: \(error.localizedDescription)")
            }
        }
    }

    static func error(status: Int, body: Data, whileAuthenticating: Bool = false) -> ServiceError {
        let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { json -> String? in
            ((json["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? (json["error_description"] as? String)
        }
        switch status {
        case 400 where whileAuthenticating, 401 where whileAuthenticating: return .invalid("eBay rejected the App ID / Cert ID. Check that they are the Production keys.")
        case 401, 403: return .invalid("eBay denied access to its Browse API for these keys" + (detail.map { " (\($0))" } ?? "."))
        case 429: return .invalid("eBay's request limit was reached. Try again later.")
        case 500...599: return .invalid("eBay is temporarily unavailable.")
        default: return .invalid("eBay request failed (\(status))" + (detail.map { ": \($0)" } ?? "."))
        }
    }
}

/// Active-listing comparables from the eBay Browse API. Browse has no sold data: every result is an asking price.
struct EbayBrowseMarketResearchService: MarketResearchService {
    private let configuration: EbayConfiguration
    private let session: URLSession
    private let tokens: any EbayAppTokenSource

    init(configuration: EbayConfiguration, session: URLSession = .shared, appTokens: (any EbayAppTokenSource)? = nil) {
        self.configuration = configuration; self.session = session
        self.tokens = appTokens ?? configuration.credentials.map { EbayTokenProvider(credentials: $0, baseURL: configuration.baseURL, session: session) } ?? MissingAppTokenSource()
    }

    func research(item: SellItem) async throws -> [MarketComparable] {
        let queries = Self.queries(for: item)
        guard !queries.isEmpty else { throw ServiceError.invalid("Add a product name to look up comparable listings.") }
        var best: [MarketComparable] = []
        for query in queries {
            let found = try await search(query: query, condition: item.condition)
            if found.count >= configuration.minimumListings { return found }
            if found.count > best.count { best = found }
        }
        guard !best.isEmpty else { throw ServiceError.invalid("No comparable eBay listings were found.") }
        return best
    }

    /// Most specific first (brand + model), then the product title.
    static func queries(for item: SellItem) -> [String] {
        func clean(_ text: String) -> String { String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80)) }
        var result: [String] = []
        let brand = item.brand.trimmingCharacters(in: .whitespaces), model = item.model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty { result.append(clean(brand.lowercased() == "unknown" ? model : "\(brand) \(model)")) }
        let title = clean(item.title)
        if !title.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) { result.append(title) }
        return result.filter { !$0.isEmpty }
    }

    /// Broad NEW/USED groups work in every category. Specific IDs do not: books use 2750/4000/5000/6000, so a filter on the
    /// generic "Used" ID (3000) hid every book. Only "for parts" has its own ID, and it is the same everywhere.
    static func conditionFilter(for condition: ItemCondition) -> String {
        switch condition { case .new: "conditions:{NEW}"; case .excellent, .good, .fair: "conditions:{USED}"; case .parts: "conditionIds:{7000}" }
    }

    func makeSearchRequest(query: String, condition: ItemCondition, token: String, filterByCondition: Bool = true) -> URLRequest {
        var components = URLComponents(url: configuration.baseURL.appending(path: "buy/browse/v1/item_summary/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(configuration.resultLimit)),
            URLQueryItem(name: "filter", value: (["buyingOptions:{FIXED_PRICE}", "priceCurrency:USD"] + (filterByCondition ? [Self.conditionFilter(for: condition)] : [])).joined(separator: ",")),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.marketplaceID, forHTTPHeaderField: "X-EBAY-C-MARKETPLACE-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func search(query: String, condition: ItemCondition) async throws -> [MarketComparable] {
        var refreshed = false, filterByCondition = true
        while true {
            let token = try await tokens.accessToken(forceRefresh: refreshed)
            let (data, response) = try await EbayHTTP.perform(makeSearchRequest(query: query, condition: condition, token: token, filterByCondition: filterByCondition), session: session)
            if response.statusCode == 401, !refreshed { refreshed = true; continue }
            // If eBay rejects the condition filter for some category, search without it rather than finding nothing.
            if response.statusCode == 400, filterByCondition { filterByCondition = false; continue }
            guard (200..<300).contains(response.statusCode) else { throw EbayHTTP.error(status: response.statusCode, body: data) }
            return Self.parse(data, fallbackCondition: condition)
        }
    }

    static func parse(_ data: Data, fallbackCondition: ItemCondition) -> [MarketComparable] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["itemSummaries"] as? [[String: Any]] else { return [] }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { entry in
            guard let title = entry["title"] as? String,
                  let price = entry["price"] as? [String: Any], price["currency"] as? String == "USD",
                  let value = (price["value"] as? String).flatMap(Double.init) ?? price["value"] as? Double, value > 0, value.isFinite else { return nil }
            let condition = (entry["conditionId"] as? String).flatMap(Int.init).map(Self.condition(forID:)) ?? fallbackCondition
            let date = (entry["itemCreationDate"] as? String).flatMap(formatter.date(from:)) ?? Date()
            return MarketComparable(title: title, marketplace: .ebay, price: value, status: .active, condition: condition, date: date, url: (entry["itemWebUrl"] as? String).flatMap(URL.init(string:)))
        }
    }

    private static func condition(forID id: Int) -> ItemCondition {
        switch id { case 1000, 1500, 1750: .new; case 2000...2030: .excellent; case 7000: .parts; default: .good }
    }
}

/// Prices from active asking prices only. Sold prices are not observed, so the sale estimate is an assumption, labeled as such.
struct AskingPricePricingService: PricingAnalysisService {
    /// Typical gap between asking and final sale prices. An assumption, to be replaced by observed sold data.
    static let assumedSaleDiscount = 0.85
    static let minimumListings = 3

    func analyze(item: SellItem, comparables: [MarketComparable]) async throws -> PricingRecommendation {
        let asking = comparables.filter { $0.status == .active }.map(\.price).filter { $0 > 0 && $0.isFinite }.sorted()
        guard asking.count >= Self.minimumListings else {
            throw ServiceError.invalid("Only \(asking.count) comparable listing\(asking.count == 1 ? "" : "s") found; not enough to suggest a price.")
        }
        let trim = asking.count >= 10 ? asking.count / 10 : 0
        let core = Array(asking.dropFirst(trim).dropLast(trim))
        let median = Self.percentile(core, 0.5)
        func rounded(_ value: Double) -> Double { max(1, value.rounded()) }
        let confidence = asking.count < 5 ? 0.3 : asking.count < 15 ? 0.45 : 0.6
        let verified = comparables.filter { $0.status == .active }.allSatisfy { $0.verifiedMatch == true }
        let basis = verified ? "\(asking.count) active eBay listings of the same model and configuration (matched by AI)"
                             : "\(asking.count) active eBay listings (not checked for matching configuration, so they may include kits or accessories)"
        return PricingRecommendation(
            sellFastPrice: rounded(median * 0.80), recommendedPrice: rounded(median * 0.90), maximizeReturnPrice: rounded(median),
            soldMedian: rounded(median * Self.assumedSaleDiscount), askingMedian: median,
            soldLow: rounded(Self.percentile(core, 0.25) * Self.assumedSaleDiscount), soldHigh: rounded(Self.percentile(core, 0.75) * Self.assumedSaleDiscount),
            confidence: confidence,
            rationale: "Suggestions sit 0–20% under the median asking price of similar eBay listings, because items usually sell for less than they are listed for. They are estimates, not observed sales.",
            dataSourceSummary: "Based on \(basis); median asking \(median.money). Sale-price estimates assume sales close about 15% below asking; sold prices are not observed.",
            marketplace: .ebay, source: "ebay-browse-active")
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
