import Foundation

enum EbaySellEnvironment: String, Codable {
    case sandbox, production
    var apiBase: URL { URL(string: self == .sandbox ? "https://api.sandbox.ebay.com" : "https://api.ebay.com")! }
    var mediaBase: URL { URL(string: self == .sandbox ? "https://apim.sandbox.ebay.com" : "https://apim.ebay.com")! }
    var listingBase: String { self == .sandbox ? "https://sandbox.ebay.com/itm/" : "https://www.ebay.com/itm/" }
    var label: String { self == .sandbox ? "eBay Sandbox (test listings)" : "eBay" }
}

struct EbayCategory: Equatable, Identifiable { var id: String; var name: String; var path: String }
struct EbayAspect: Equatable {
    var name: String; var required: Bool; var selectionOnly: Bool; var multiValue: Bool; var values: [String]
    /// The allowed value matching `value` ignoring case, if the aspect restricts values; otherwise `value` itself.
    func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard selectionOnly else { return trimmed }
        return values.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}
struct EbayPublishResult: Equatable { var offerID: String; var listingID: String; var url: URL }

protocol EbayListingService {
    var environment: EbaySellEnvironment { get }
    func suggestCategories(query: String) async throws -> [EbayCategory]
    func aspects(for categoryID: String) async throws -> [EbayAspect]
    func publish(draft: ListingDraft, photos: [SellItemPhoto], conditionNotes: String) async throws -> EbayPublishResult
    func withdraw(offerID: String) async throws
}

/// Fills eBay item specifics from what is known about the item. Returns only values it is confident about.
protocol ItemSpecificsService {
    func fill(item: SellItem, aspects: [EbayAspect]) async throws -> [String: String]
}

enum EbaySpecifics {
    /// Facts we already hold, matched to required aspect names. Never overwrites a value the seller has set.
    static func prefill(item: SellItem, existing: [String: String], aspects: [EbayAspect]) -> [String: String] {
        var result = existing
        func current(_ aspect: EbayAspect) -> String? { result.first { $0.key.caseInsensitiveCompare(aspect.name) == .orderedSame && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }?.value }
        for aspect in aspects where aspect.required && current(aspect) == nil {
            let known: String
            switch aspect.name.lowercased() {
            case "brand": known = item.brand.lowercased() == "unknown" ? "" : item.brand
            case "model", "mpn", "manufacturer part number": known = item.model
            case "color", "colour": known = item.color
            default: continue
            }
            if let value = aspect.normalized(known) { result[aspect.name] = value }
        }
        return result
    }

    static func missing(_ aspects: [EbayAspect], in specifics: [String: String]) -> [String] {
        aspects.filter { $0.required }.map(\.name).filter { name in
            (specifics.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

struct EbaySellConfiguration {
    var environment: EbaySellEnvironment = .sandbox
    /// nil when application tokens come from the token server.
    var credentials: EbayCredentials?
    var tokens: any EbayUserTokenSource
    var marketplaceID = "EBAY_US"
    var locationKey = "SELLPILOT_HOME"
    /// Where items ship from. The sandbox default is a placeholder; production must use the seller's real location.
    var locationPostalCode = "95125"
}

struct EbaySellService: EbayListingService {
    let configuration: EbaySellConfiguration
    private let session: URLSession
    private let appTokens: any EbayAppTokenSource
    var environment: EbaySellEnvironment { configuration.environment }

    init(configuration: EbaySellConfiguration, session: URLSession = .shared, appTokens: (any EbayAppTokenSource)? = nil) {
        self.configuration = configuration; self.session = session
        self.appTokens = appTokens ?? configuration.credentials.map { EbayTokenProvider(credentials: $0, baseURL: configuration.environment.apiBase, session: session) } ?? MissingAppTokenSource()
    }

    // MARK: HTTP

    private func send(_ method: String, _ url: URL, query: [URLQueryItem] = [], token: String, json: Any? = nil, multipart: (field: String, filename: String, data: Data)? = nil) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let multipart {
            let boundary = "sellpilot-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(multipart.field)\"; filename=\"\(multipart.filename)\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(multipart.data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
        } else if method == "POST" || method == "PUT" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("en-US", forHTTPHeaderField: "Content-Language")
            // An explicit (possibly empty) body keeps eBay's edge from rejecting body-less POSTs such as publish with 411.
            request.httpBody = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        }
        return try await EbayHTTP.perform(request, session: session)
    }

    /// A call made as the signed-in seller. If eBay rejects the token (401), it is refreshed and the call is tried once more.
    private func asSeller(_ method: String, _ url: URL, query: [URLQueryItem] = [], json: Any? = nil, multipart: (field: String, filename: String, data: Data)? = nil) async throws -> (Data, HTTPURLResponse) {
        let result = try await send(method, url, query: query, token: try await configuration.tokens.accessToken(), json: json, multipart: multipart)
        guard result.1.statusCode == 401 else { return result }
        return try await send(method, url, query: query, token: try await configuration.tokens.refreshedAccessToken(), json: json, multipart: multipart)
    }

    private func sell(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        try await asSeller(method, configuration.environment.apiBase.appending(path: path), query: query, json: json)
    }

    private func object(_ data: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
    private func errorIDs(_ data: Data) -> [Int] { (object(data)["errors"] as? [[String: Any]])?.compactMap { $0["errorId"] as? Int } ?? [] }

    /// Turns an eBay failure into a message the seller can act on.
    static func failure(_ status: Int, _ data: Data) -> ServiceError {
        let errors = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["errors"] as? [[String: Any]]) ?? []
        let messages = errors.compactMap { $0["message"] as? String }
        if status == 401 || errors.contains(where: { $0["errorId"] as? Int == 1001 }) { return .invalid("Your eBay sign-in has expired. Reconnect eBay in Settings.") }
        if status == 403 { return .invalid("eBay says this account isn't allowed to do that" + (messages.first.map { ": \($0)" } ?? ".")) }
        if messages.isEmpty { return .invalid("eBay request failed (\(status)).") }
        return .invalid("eBay: " + messages.prefix(3).joined(separator: " "))
    }

    private func expect(_ allowed: Set<Int>, _ result: (Data, HTTPURLResponse)) throws -> Data {
        guard allowed.contains(result.1.statusCode) else { throw Self.failure(result.1.statusCode, result.0) }
        return result.0
    }

    // MARK: Taxonomy (application token)

    func suggestCategories(query: String) async throws -> [EbayCategory] {
        let token = try await appTokens.accessToken()
        let url = configuration.environment.apiBase.appending(path: "commerce/taxonomy/v1/category_tree/0/get_category_suggestions")
        let data = try expect([200], try await send("GET", url, query: [URLQueryItem(name: "q", value: String(query.prefix(350)))], token: token))
        return ((object(data)["categorySuggestions"] as? [[String: Any]]) ?? []).prefix(5).compactMap { suggestion in
            guard let category = suggestion["category"] as? [String: Any], let id = category["categoryId"] as? String, let name = category["categoryName"] as? String else { return nil }
            let ancestors = ((suggestion["categoryTreeNodeAncestors"] as? [[String: Any]]) ?? []).sorted { ($0["categoryTreeNodeLevel"] as? Int ?? 0) < ($1["categoryTreeNodeLevel"] as? Int ?? 0) }.compactMap { $0["categoryName"] as? String }
            return EbayCategory(id: id, name: name, path: (ancestors + [name]).joined(separator: " › "))
        }
    }

    func aspects(for categoryID: String) async throws -> [EbayAspect] {
        let token = try await appTokens.accessToken()
        let url = configuration.environment.apiBase.appending(path: "commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category")
        let data = try expect([200], try await send("GET", url, query: [URLQueryItem(name: "category_id", value: categoryID)], token: token))
        return ((object(data)["aspects"] as? [[String: Any]]) ?? []).compactMap { aspect in
            guard let name = aspect["localizedAspectName"] as? String else { return nil }
            let constraint = aspect["aspectConstraint"] as? [String: Any] ?? [:]
            return EbayAspect(name: name, required: constraint["aspectRequired"] as? Bool ?? false, selectionOnly: constraint["aspectMode"] as? String == "SELECTION_ONLY",
                              multiValue: constraint["itemToAspectCardinality"] as? String == "MULTI",
                              values: ((aspect["aspectValues"] as? [[String: Any]]) ?? []).compactMap { $0["localizedValue"] as? String })
        }
    }

    // MARK: Seller setup (user token)

    struct SellerSetup: Equatable { var fulfillmentPolicyID: String; var paymentPolicyID: String; var returnPolicyID: String }

    func ensureSellerSetup() async throws -> SellerSetup {
        // Already opted in answers 409/25804, which is fine; any real problem shows up as missing policies below.
        _ = try? await sell("POST", "sell/account/v1/program/opt_in", json: ["programType": "SELLING_POLICY_MANAGEMENT"])
        let categoryTypes: [[String: Any]] = [["name": "ALL_EXCLUDING_MOTORS_VEHICLES", "default": true]]
        let stamp = String(Int(Date().timeIntervalSince1970))
        let kinds: [(path: String, list: String, id: String, label: String, create: [String: Any])] = [
            ("fulfillment_policy", "fulfillmentPolicies", "fulfillmentPolicyId", "shipping", ["name": "SellPilot shipping \(stamp)", "marketplaceId": configuration.marketplaceID, "categoryTypes": categoryTypes, "handlingTime": ["value": 3, "unit": "DAY"],
                "shippingOptions": [["optionType": "DOMESTIC", "costType": "FLAT_RATE", "shippingServices": [["sortOrder": 1, "shippingCarrierCode": "USPS", "shippingServiceCode": "USPSPriority", "freeShipping": false, "shippingCost": ["value": "8.00", "currency": "USD"]]]]]]),
            ("payment_policy", "paymentPolicies", "paymentPolicyId", "payment", ["name": "SellPilot payment \(stamp)", "marketplaceId": configuration.marketplaceID, "categoryTypes": categoryTypes]),
            ("return_policy", "returnPolicies", "returnPolicyId", "return", ["name": "SellPilot returns \(stamp)", "marketplaceId": configuration.marketplaceID, "categoryTypes": categoryTypes, "returnsAccepted": false]),
        ]
        var ids: [String: String] = [:]
        for kind in kinds {
            let listed = object(try expect([200], try await sell("GET", "sell/account/v1/\(kind.path)", query: [URLQueryItem(name: "marketplace_id", value: configuration.marketplaceID)])))
            if let existing = (listed[kind.list] as? [[String: Any]])?.first?[kind.id] as? String { ids[kind.id] = existing; continue }
            // Sandbox test sellers start with no policies, so defaults are created. A real seller must choose their own
            // shipping, payment and return terms, which SellPilot will not invent.
            guard configuration.environment == .sandbox else { throw ServiceError.invalid("Set up a \(kind.label) policy in eBay Seller Hub (Account > Business policies), then try again.") }
            let created = object(try expect([200, 201], try await sell("POST", "sell/account/v1/\(kind.path)", json: kind.create)))
            guard let id = created[kind.id] as? String else { throw ServiceError.invalid("eBay did not return a \(kind.label) policy.") }
            ids[kind.id] = id
        }
        let location = try await sell("GET", "sell/inventory/v1/location/\(configuration.locationKey)")
        if location.1.statusCode != 200 {
            let body: [String: Any] = ["location": ["address": ["postalCode": configuration.locationPostalCode, "country": "US"]], "locationTypes": ["WAREHOUSE"], "name": "SellPilot location", "merchantLocationStatus": "ENABLED"]
            let created = try await sell("POST", "sell/inventory/v1/location/\(configuration.locationKey)", json: body)
            guard [200, 201, 204].contains(created.1.statusCode) || errorIDs(created.0).contains(25803) else { throw Self.failure(created.1.statusCode, created.0) }
        }
        return SellerSetup(fulfillmentPolicyID: ids["fulfillmentPolicyId"]!, paymentPolicyID: ids["paymentPolicyId"]!, returnPolicyID: ids["returnPolicyId"]!)
    }

    // MARK: Photos

    func uploadImage(_ photo: SellItemPhoto) async throws -> URL {
        guard let source = [photo.previewData, photo.originalData].compactMap({ $0 }).first(where: { !$0.isEmpty }),
              let jpeg = ImageResizer.jpeg(from: source, maxPixel: 2000, quality: 0.85) else { throw ServiceError.invalid("A photo could not be read. Remove it and add it again.") }
        let upload = try await asSeller("POST", configuration.environment.mediaBase.appending(path: "commerce/media/v1_beta/image/create_image_from_file"), multipart: ("image", "photo.jpg", jpeg))
        guard [200, 201].contains(upload.1.statusCode) else { throw Self.failure(upload.1.statusCode, upload.0) }
        guard let location = upload.1.value(forHTTPHeaderField: "Location"), let imageURL = URL(string: location) else { throw ServiceError.invalid("eBay accepted the photo but did not say where it is.") }
        let details = object(try expect([200], try await asSeller("GET", imageURL)))
        guard let hosted = (details["imageUrl"] as? String).flatMap(URL.init(string:)) else { throw ServiceError.invalid("eBay did not return a hosted photo address.") }
        return hosted
    }

    // MARK: Publish

    static func conditionEnum(_ condition: ItemCondition) -> String {
        switch condition { case .new: "NEW"; case .excellent: "USED_EXCELLENT"; case .good: "USED_GOOD"; case .fair: "USED_ACCEPTABLE"; case .parts: "FOR_PARTS_OR_NOT_WORKING" }
    }
    static func sku(for draft: ListingDraft) -> String { "SP" + draft.id.uuidString.replacingOccurrences(of: "-", with: "") }
    static func html(_ text: String) -> String {
        "<p>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n\n", with: "</p><p>").replacingOccurrences(of: "\n", with: "<br>") + "</p>"
    }

    func publish(draft: ListingDraft, photos: [SellItemPhoto], conditionNotes: String) async throws -> EbayPublishResult {
        guard configuration.environment == .sandbox else { throw ServiceError.invalid("Publishing to real eBay isn't enabled yet. Use the sandbox for test listings.") }
        guard let categoryID = draft.ebayCategoryID, !categoryID.isEmpty else { throw ServiceError.invalid("Choose an eBay category first.") }
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty, draft.price > 0, !photos.isEmpty else { throw ServiceError.invalid("A title, a positive price and at least one photo are required.") }
        let setup = try await ensureSellerSetup()
        var imageURLs: [String] = []
        for photo in photos.prefix(24) { imageURLs.append(try await uploadImage(photo).absoluteString) }

        let sku = Self.sku(for: draft)
        let aspects = draft.itemSpecifics.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }.mapValues { [$0] }
        var item: [String: Any] = [
            "availability": ["shipToLocationAvailability": ["quantity": 1]], "condition": Self.conditionEnum(draft.condition),
            "product": ["title": String(draft.title.prefix(80)), "description": Self.html(draft.description), "aspects": aspects, "imageUrls": imageURLs],
        ]
        if !conditionNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item["conditionDescription"] = String(conditionNotes.prefix(1000)) }
        _ = try expect([200, 204], try await sell("PUT", "sell/inventory/v1/inventory_item/\(sku)", json: item))

        let offer: [String: Any] = [
            "sku": sku, "marketplaceId": configuration.marketplaceID, "format": "FIXED_PRICE", "availableQuantity": 1, "categoryId": categoryID, "merchantLocationKey": configuration.locationKey,
            "listingDescription": Self.html(draft.description), "pricingSummary": ["price": ["value": String(format: "%.2f", draft.price), "currency": "USD"]],
            "listingPolicies": ["fulfillmentPolicyId": setup.fulfillmentPolicyID, "paymentPolicyId": setup.paymentPolicyID, "returnPolicyId": setup.returnPolicyID],
        ]
        let offerID = try await upsertOffer(offer, sku: sku)
        let published = object(try expect([200], try await sell("POST", "sell/inventory/v1/offer/\(offerID)/publish")))
        guard let listingID = published["listingId"] as? String, let url = URL(string: Self.listingURL(configuration.environment, listingID)) else { throw ServiceError.invalid("eBay did not return a listing ID.") }
        return EbayPublishResult(offerID: offerID, listingID: listingID, url: url)
    }

    static func listingURL(_ environment: EbaySellEnvironment, _ id: String) -> String { environment.listingBase + id }

    /// Creates the offer, or replaces the existing one for this SKU (a previous attempt may have failed at publish).
    private func upsertOffer(_ offer: [String: Any], sku: String) async throws -> String {
        let created = try await sell("POST", "sell/inventory/v1/offer", json: offer)
        if [200, 201].contains(created.1.statusCode), let id = object(created.0)["offerId"] as? String { return id }
        let existing = object(try expect([200], try await sell("GET", "sell/inventory/v1/offer", query: [URLQueryItem(name: "sku", value: sku), URLQueryItem(name: "marketplace_id", value: configuration.marketplaceID)])))
        guard let id = (existing["offers"] as? [[String: Any]])?.first?["offerId"] as? String else { throw Self.failure(created.1.statusCode, created.0) }
        _ = try expect([200, 204], try await sell("PUT", "sell/inventory/v1/offer/\(id)", json: offer))
        return id
    }

    func withdraw(offerID: String) async throws {
        _ = try expect([200, 204], try await sell("POST", "sell/inventory/v1/offer/\(offerID)/withdraw"))
    }
}
