import XCTest
import SwiftData
@testable import SellPilot

private final class SellStub: URLProtocol {
    struct Reply { var status = 200; var body: Any = [String: Any](); var headers: [String: String] = [:] }
    static var route: ((URLRequest, Data) -> Reply)?
    static var log: [(method: String, path: String, query: String, body: Data, request: URLRequest)] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 65_536); body = Data()
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let url = request.url!
        Self.log.append((request.httpMethod ?? "", url.path, url.query ?? "", body, request))
        let reply = Self.route!(request, body)
        let data = (reply.body as? Data) ?? (try! JSONSerialization.data(withJSONObject: reply.body))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EbaySellTests: XCTestCase {
    fileprivate typealias Reply = SellStub.Reply
    override func setUp() {
        SellStub.log = []; SellStub.route = nil
        PhotoStorage.shared = PhotoStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)"))
    }

    private func service(_ environment: EbaySellEnvironment = .sandbox) -> EbaySellService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SellStub.self]
        return EbaySellService(configuration: .init(environment: environment, credentials: .init(appID: "app", certID: "cert"), tokens: StaticEbayTokenSource(token: "user-token")), session: URLSession(configuration: config))
    }
    private func liveService(allow: Bool, zip: String) -> EbaySellService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SellStub.self]
        var configuration = EbaySellConfiguration(environment: .production, credentials: .init(appID: "app", certID: "cert"), tokens: StaticEbayTokenSource(token: "user-token"))
        configuration.allowLivePublishing = allow; configuration.locationPostalCode = zip; configuration.locationKey = "SELLPILOT_\(zip)"
        return EbaySellService(configuration: configuration, session: URLSession(configuration: config))
    }
    private func service(tokens: any EbayUserTokenSource) -> EbaySellService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SellStub.self]
        return EbaySellService(configuration: .init(environment: .sandbox, credentials: .init(appID: "app", certID: "cert"), tokens: tokens), session: URLSession(configuration: config))
    }
    private func draft(category: String? = "168134") throws -> (ListingDraft, [SellItemPhoto]) {
        let photo = try SellItemPhoto(originalData: try XCTUnwrap(PhotoImport.normalized(PhotoImport.demoPhoto())))
        var draft = ListingDraft(marketplace: .ebay, title: String(repeating: "T", count: 100), description: "Works.\n\nA & B <ok>", price: 49.99, condition: .good, category: "x", keywords: [], itemSpecifics: ["Brand": "DEWALT", "Battery Included": "No", "Voltage": "20V", "Not an aspect": "x"], shippingNotes: "", localPickupNotes: "", photoOrder: [photo.id])
        draft.ebayCategoryID = category
        return (draft, [photo])
    }
    /// A seller who already has policies and a location.
    fileprivate func happyRoute(_ request: URLRequest, _ body: Data) -> Reply {
        let path = request.url!.path, method = request.httpMethod ?? ""
        switch (method, path) {
        case ("POST", "/identity/v1/oauth2/token"): return Reply(body: ["access_token": "app-token", "expires_in": 7200])
        case ("POST", "/sell/account/v1/program/opt_in"): return Reply(status: 409, body: ["errors": [["errorId": 25804, "message": "already"]]])
        case ("GET", "/sell/account/v1/fulfillment_policy"): return Reply(body: ["fulfillmentPolicies": [["fulfillmentPolicyId": "F1"]]])
        case ("GET", "/sell/account/v1/payment_policy"): return Reply(body: ["paymentPolicies": [["paymentPolicyId": "P1"]]])
        case ("GET", "/sell/account/v1/return_policy"): return Reply(body: ["returnPolicies": [["returnPolicyId": "R1"]]])
        case ("GET", "/sell/inventory/v1/location/SELLPILOT_HOME"): return Reply(body: ["merchantLocationKey": "SELLPILOT_HOME"])
        case ("POST", "/commerce/media/v1_beta/image/create_image_from_file"): return Reply(status: 201, headers: ["Location": "https://api.sandbox.ebay.com/commerce/media/v1_beta/image/IMG1"])
        case ("GET", "/commerce/media/v1_beta/image/IMG1"): return Reply(body: ["imageUrl": "https://i.sandbox.ebayimg.com/IMG1.JPG"])
        case ("PUT", _) where path.hasPrefix("/sell/inventory/v1/inventory_item/"): return Reply(status: 204)
        case ("POST", "/sell/inventory/v1/offer"): return Reply(status: 201, body: ["offerId": "OFFER1"])
        case ("POST", "/sell/inventory/v1/offer/OFFER1/publish"): return Reply(body: ["listingId": "110591201126"])
        case ("POST", "/sell/inventory/v1/offer/OFFER1/withdraw"): return Reply()
        default: return Reply(status: 404, body: ["errors": [["errorId": 1, "message": "unexpected \(method) \(path)"]]])
        }
    }

    func testPublishRunsTheSequenceThatWorkedInTheSandbox() async throws {
        SellStub.route = happyRoute
        let (draft, photos) = try draft()
        let result = try await service().publish(draft: draft, photos: photos, conditionNotes: "Scuffs")
        XCTAssertEqual(result.listingID, "110591201126"); XCTAssertEqual(result.offerID, "OFFER1"); XCTAssertEqual(result.url.absoluteString, "https://sandbox.ebay.com/itm/110591201126")

        let order = SellStub.log.map { "\($0.method) \($0.path)" }.filter { !$0.contains("oauth2") }
        let expected = ["POST /sell/account/v1/program/opt_in", "GET /sell/account/v1/fulfillment_policy", "GET /sell/account/v1/payment_policy", "GET /sell/account/v1/return_policy", "GET /sell/inventory/v1/location/SELLPILOT_HOME",
                        "POST /commerce/media/v1_beta/image/create_image_from_file", "GET /commerce/media/v1_beta/image/IMG1"]
        XCTAssertEqual(Array(order.prefix(expected.count)), expected)
        XCTAssertTrue(order.last == "POST /sell/inventory/v1/offer/OFFER1/publish")

        let upload = try XCTUnwrap(SellStub.log.first { $0.path.hasSuffix("create_image_from_file") })
        XCTAssertTrue(upload.request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(String(decoding: upload.body.prefix(400), as: UTF8.self).contains("name=\"image\""))
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "Authorization"), "Bearer user-token")

        let item = try XCTUnwrap(SellStub.log.first { $0.method == "PUT" })
        let itemJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: item.body) as? [String: Any])
        XCTAssertEqual(itemJSON["condition"] as? String, "USED_GOOD"); XCTAssertEqual(itemJSON["conditionDescription"] as? String, "Scuffs")
        let product = try XCTUnwrap(itemJSON["product"] as? [String: Any])
        XCTAssertEqual((product["title"] as? String)?.count, 80); XCTAssertEqual(product["imageUrls"] as? [String], ["https://i.sandbox.ebayimg.com/IMG1.JPG"])
        XCTAssertEqual((product["aspects"] as? [String: [String]])?["Battery Included"], ["No"])
        XCTAssertEqual(product["description"] as? String, "<p>Works.</p><p>A &amp; B &lt;ok&gt;</p>")
        XCTAssertEqual(item.request.value(forHTTPHeaderField: "Content-Language"), "en-US")

        let offer = try XCTUnwrap(SellStub.log.first { $0.method == "POST" && $0.path == "/sell/inventory/v1/offer" })
        let offerJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: offer.body) as? [String: Any])
        XCTAssertEqual(offerJSON["categoryId"] as? String, "168134"); XCTAssertEqual(offerJSON["format"] as? String, "FIXED_PRICE")
        XCTAssertEqual(((offerJSON["pricingSummary"] as? [String: Any])?["price"] as? [String: String]), ["value": "49.99", "currency": "USD"])
        XCTAssertEqual((offerJSON["listingPolicies"] as? [String: String])?["returnPolicyId"], "R1")

        let publish = try XCTUnwrap(SellStub.log.last)
        XCTAssertEqual(publish.request.value(forHTTPHeaderField: "Content-Type"), "application/json", "publish sends an explicit body so eBay does not answer 411")
    }

    func testSandboxCreatesMissingPoliciesAndLocationButProductionRefusesToInventTerms() async throws {
        SellStub.route = { request, body in
            let path = request.url!.path, method = request.httpMethod ?? ""
            if method == "GET", path.contains("_policy") { return Reply(body: [String: Any]()) }
            if method == "GET", path.contains("/location/") { return Reply(status: 404) }
            if method == "POST", path.hasSuffix("fulfillment_policy") { return Reply(status: 201, body: ["fulfillmentPolicyId": "F9"]) }
            if method == "POST", path.hasSuffix("payment_policy") { return Reply(status: 201, body: ["paymentPolicyId": "P9"]) }
            if method == "POST", path.hasSuffix("return_policy") { return Reply(status: 201, body: ["returnPolicyId": "R9"]) }
            if method == "POST", path.contains("/location/") { return Reply(status: 204) }
            return self.happyRoute(request, body)
        }
        let setup = try await service().ensureSellerSetup()
        XCTAssertEqual(setup, .init(fulfillmentPolicyID: "F9", paymentPolicyID: "P9", returnPolicyID: "R9"))
        XCTAssertTrue(SellStub.log.contains { $0.method == "POST" && $0.path == "/sell/inventory/v1/location/SELLPILOT_HOME" })
        do { _ = try await service(.production).ensureSellerSetup(); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("Seller Hub")) }
        let (draft, photos) = try draft()
        do { _ = try await service(.production).publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("isn't enabled")) }
    }

    func testRetryReplacesTheExistingOfferWhenOneAlreadyExistsForTheSKU() async throws {
        SellStub.route = { request, body in
            let path = request.url!.path, method = request.httpMethod ?? ""
            if method == "POST", path == "/sell/inventory/v1/offer" { return Reply(status: 400, body: ["errors": [["errorId": 25002, "message": "Offer already exists"]]]) }
            if method == "GET", path == "/sell/inventory/v1/offer" { return Reply(body: ["offers": [["offerId": "OFFER1"]]]) }
            if method == "PUT", path == "/sell/inventory/v1/offer/OFFER1" { return Reply(status: 204) }
            return self.happyRoute(request, body)
        }
        let (draft, photos) = try draft()
        let result = try await service().publish(draft: draft, photos: photos, conditionNotes: "")
        XCTAssertEqual(result.offerID, "OFFER1"); XCTAssertTrue(SellStub.log.contains { $0.method == "PUT" && $0.path == "/sell/inventory/v1/offer/OFFER1" })
    }

    func testErrorsBecomeActionableMessages() async throws {
        SellStub.route = { request, body in
            if request.url!.path.contains("inventory_item") { return Reply(status: 400, body: ["errors": [["errorId": 25002, "message": "Item specific Voltage is missing."], ["errorId": 2, "message": "Second problem."]]]) }
            return self.happyRoute(request, body)
        }
        let (draft, photos) = try draft()
        do { _ = try await service().publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "While saving the item: eBay: Item specific Voltage is missing. Second problem.") }
        XCTAssertTrue(EbaySellService.failure(401, Data()).localizedDescription.contains("expired"))
        XCTAssertTrue(EbaySellService.failure(500, Data(#"{"errors":[{"errorId":1001,"message":"Invalid access token"}]}"#.utf8)).localizedDescription.contains("expired"))
        XCTAssertEqual(EbaySellService.failure(500, Data()).localizedDescription, "eBay request failed (500).")
    }

    func testTaxonomyParsingAndWithdraw() async throws {
        SellStub.route = { request, body in
            switch request.url!.path {
            case "/commerce/taxonomy/v1/category_tree/0/get_category_suggestions":
                return Reply(body: ["categorySuggestions": [["category": ["categoryId": "168134", "categoryName": "Impact Drivers"], "categoryTreeNodeAncestors": [["categoryName": "Power Tools", "categoryTreeNodeLevel": 2], ["categoryName": "Business & Industrial", "categoryTreeNodeLevel": 1]]]]])
            case "/commerce/taxonomy/v1/category_tree/0/get_item_aspects_for_category":
                return Reply(body: ["aspects": [
                    ["localizedAspectName": "Brand", "aspectConstraint": ["aspectRequired": true, "aspectMode": "FREE_TEXT", "itemToAspectCardinality": "SINGLE"]],
                    ["localizedAspectName": "Battery Included", "aspectConstraint": ["aspectRequired": true, "aspectMode": "SELECTION_ONLY"], "aspectValues": [["localizedValue": "Yes"], ["localizedValue": "No"]]],
                    ["localizedAspectName": "Color", "aspectConstraint": ["aspectRequired": false, "itemToAspectCardinality": "MULTI"]]]])
            default: return self.happyRoute(request, body)
            }
        }
        let svc = service()
        let categories = try await svc.suggestCategories(query: "impact driver")
        XCTAssertEqual(categories, [EbayCategory(id: "168134", name: "Impact Drivers", path: "Business & Industrial › Power Tools › Impact Drivers")])
        let aspects = try await svc.aspects(for: "168134")
        XCTAssertEqual(aspects.filter(\.required).map(\.name), ["Brand", "Battery Included"])
        XCTAssertTrue(aspects[1].selectionOnly); XCTAssertEqual(aspects[1].values, ["Yes", "No"]); XCTAssertTrue(aspects[2].multiValue)
        XCTAssertEqual(SellStub.log.first { $0.path.contains("taxonomy") }?.request.value(forHTTPHeaderField: "Authorization"), "Bearer app-token", "taxonomy uses the application token")
        try await svc.withdraw(offerID: "OFFER1")
        XCTAssertEqual(SellStub.log.last?.path, "/sell/inventory/v1/offer/OFFER1/withdraw")
    }

    func testPrefillAndMissingRespectRestrictedValuesAndSellerEdits() {
        let aspects = [EbayAspect(name: "Brand", required: true, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Battery Included", required: true, selectionOnly: true, multiValue: false, values: ["Yes", "No"]),
                       EbayAspect(name: "Color", required: true, selectionOnly: true, multiValue: false, values: ["Black", "Yellow"]),
                       EbayAspect(name: "Voltage", required: true, selectionOnly: false, multiValue: false, values: [])]
        var item = SellItem(); item.brand = "DEWALT"; item.color = "yellow"
        let filled = EbaySpecifics.prefill(item: item, existing: ["brand": "My Brand"], aspects: aspects)
        XCTAssertEqual(filled["brand"], "My Brand", "never overwrites the seller's value"); XCTAssertNil(filled["Brand"])
        XCTAssertEqual(filled["Color"], "Yellow", "normalized to eBay's allowed spelling")
        XCTAssertEqual(EbaySpecifics.missing(aspects, in: filled), ["Battery Included", "Voltage"])
        item.color = "Chartreuse"
        XCTAssertNil(EbaySpecifics.prefill(item: item, existing: [:], aspects: aspects)["Color"], "a value outside the allowed list is dropped")
        item.brand = "Unknown"; XCTAssertNil(EbaySpecifics.prefill(item: item, existing: [:], aspects: aspects)["Brand"])
    }

    // MARK: Workflow

    private final class FakeEbay: EbayListingService {
        var environment = EbaySellEnvironment.sandbox
        var published: [ListingDraft] = []
        var failure: Error?
        var policyList = EbaySellerPolicies(fulfillment: [EbayPolicy(id: "F1", name: "Standard shipping"), EbayPolicy(id: "F2", name: "Express")], payment: [EbayPolicy(id: "P1", name: "Managed payments")], returns: [EbayPolicy(id: "R1", name: "30-day returns")])
        func policies() async throws -> EbaySellerPolicies { policyList }
        var aspectList = [EbayAspect(name: "Brand", required: true, selectionOnly: false, multiValue: false, values: []), EbayAspect(name: "Voltage", required: true, selectionOnly: false, multiValue: false, values: [])]
        func suggestCategories(query: String) async throws -> [EbayCategory] { [EbayCategory(id: "168134", name: "Impact Drivers", path: "Tools › Impact Drivers"), EbayCategory(id: "1", name: "Other", path: "Other")] }
        func aspects(for categoryID: String) async throws -> [EbayAspect] { aspectList }
        func publish(draft: ListingDraft, photos: [SellItemPhoto], conditionNotes: String) async throws -> EbayPublishResult { if let failure { throw failure }; published.append(draft); return EbayPublishResult(offerID: "O", listingID: "L", url: URL(string: "https://sandbox.ebay.com/itm/L")!) }
        func withdraw(offerID: String) async throws {}
    }
    private struct FakeSpecifics: ItemSpecificsService { func facts(for item: SellItem) async throws -> [String: String] { ["voltage": "20V"] } }

    /// The store must outlive the workflow, or SwiftData crashes on save.
    private var containers: [ModelContainer] = []
    @MainActor private func workflow(_ ebay: FakeEbay, specifics: (any ItemSpecificsService)? = FakeSpecifics()) throws -> SellingWorkflow {
        let container = try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        var services = AppServices(); services.ebay = ebay; services.specifics = specifics
        var seed = SellItem(); seed.title = "DEWALT impact driver"; seed.brand = "DEWALT"; seed.askingPrice = 49
        let (draft, photos) = try self.draft(category: nil)
        var d = draft; d.itemSpecifics = ["Not an aspect": "x"]
        seed.photos = photos; seed.listings = [d]; seed.status = .ready; seed.workflowStep = SellItem.lastStep
        return SellingWorkflow(item: seed, store: ItemStore(context: container.mainContext), services: services)
    }

    @MainActor func testPreparePicksACategoryAndFillsWhatItCanThenPublishNeedsTheRest() async throws {
        let ebay = FakeEbay(); let flow = try workflow(ebay, specifics: nil)
        await flow.prepareEbayListing(0)
        XCTAssertEqual(flow.item.listings[0].ebayCategoryID, "168134"); XCTAssertEqual(flow.item.listings[0].ebayCategoryName, "Tools › Impact Drivers", "the full path is kept so the menu is not just \"Women\""); XCTAssertEqual(flow.item.listings[0].itemSpecifics["Brand"], "DEWALT")
        XCTAssertEqual(flow.item.listings[0].ebayRequiredSpecifics, ["Brand", "Voltage"]); XCTAssertEqual(flow.ebayCategoryChoices.count, 2)
        await flow.publishToEbay(0)
        XCTAssertTrue(try XCTUnwrap(flow.error).contains("Voltage")); XCTAssertTrue(ebay.published.isEmpty, "nothing is sent while required details are missing")
        flow.error = nil; flow.item.listings[0].itemSpecifics["Voltage"] = "20V"
        await flow.publishToEbay(0)
        XCTAssertNil(flow.error); XCTAssertEqual(flow.item.listings[0].ebayListingID, "L"); XCTAssertEqual(flow.item.listings[0].ebayEnvironment, "sandbox")
        XCTAssertNil(ebay.published[0].itemSpecifics["Not an aspect"], "only real eBay aspects are sent")
        XCTAssertEqual(flow.item.status, .ready, "a sandbox test listing never marks the item Active")
        XCTAssertNotNil(flow.notice)
        await flow.publishToEbay(0); XCTAssertEqual(ebay.published.count, 1, "no double publish")
    }

    @MainActor func testClaudeFillsRemainingDetailsAndRealPublishMarksActive() async throws {
        let ebay = FakeEbay(); ebay.environment = .production
        let flow = try workflow(ebay)
        await flow.prepareEbayListing(0)
        XCTAssertEqual(flow.item.listings[0].itemSpecifics["Voltage"], "20V")
        await flow.publishToEbay(0)
        XCTAssertEqual(flow.item.status, .active)
        await flow.endEbayListing(0); XCTAssertNil(flow.item.listings[0].ebayListingID)
    }

    // MARK: Item facts (the only AI step for item specifics; it sees nothing from eBay)

    func testFactsServiceSendsOnlyTheSellersDescriptionAndReturnsGenericFacts() async throws {
        SellStub.route = { _, _ in Reply(body: ["content": [["type": "tool_use", "name": "report_facts", "input": ["voltage": "20V", "battery_included": "no", "color": NSNull(), "material": "unknown", "other": ["Chuck Size": "1/4 in", "Empty": ""]]]]]) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SellStub.self]
        var item = SellItem(); item.title = "DEWALT DCF887B"; item.sellerNotes = "Tool only"
        let result = try await ClaudeItemFactsService(configuration: .init(apiKey: "k"), session: URLSession(configuration: config)).facts(for: item)
        XCTAssertEqual(result, ["voltage": "20V", "battery_included": "no", "chuck_size": "1/4 in"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SellStub.log[0].body) as? [String: Any])
        let prompt = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        XCTAssertTrue(prompt.contains("Tool only")); XCTAssertTrue(prompt.contains("DCF887B"))
        XCTAssertFalse(prompt.lowercased().contains("allowed"), "no eBay allowed-value lists are sent")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
    }

    func testFactsAreMatchedToEbayAspectsOnTheDevice() {
        let aspects = [EbayAspect(name: "Battery Included", required: true, selectionOnly: true, multiValue: false, values: ["Yes", "No"]),
                       EbayAspect(name: "Voltage", required: true, selectionOnly: true, multiValue: false, values: ["18V", "20V", "12V"]),
                       EbayAspect(name: "Product Type", required: true, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Color", required: true, selectionOnly: true, multiValue: false, values: ["Black", "Yellow"]),
                       EbayAspect(name: "Brand", required: true, selectionOnly: false, multiValue: false, values: [])]
        var item = SellItem(); item.brand = "DEWALT"; item.title = "DEWALT impact driver"; item.sellerNotes = "Tool only."
        let facts = ["voltage": "20 V", "type": "Impact driver", "color": "Chartreuse", "battery_included": "yes"]
        let filled = EbaySpecifics.fill(aspects: aspects, existing: ["Brand": "DEWALT"], facts: facts, item: item)
        XCTAssertEqual(filled["Battery Included"], "No", "the seller's own wording beats a guessed fact")
        XCTAssertEqual(filled["Voltage"], "20V", "punctuation and spacing do not matter")
        XCTAssertEqual(filled["Product Type"], "Impact driver", "a fact named Type fills Product Type")
        XCTAssertNil(filled["Color"], "a value eBay does not allow is left for the seller")
        XCTAssertEqual(filled["Brand"], "DEWALT", "existing values are kept")
        item.sellerNotes = ""
        XCTAssertEqual(EbaySpecifics.fill(aspects: [aspects[0]], existing: [:], facts: ["battery_included": "yes"], item: item)["Battery Included"], "Yes", "yes/no facts map to eBay's Yes/No")
    }

    private struct RotatingTokens: EbayUserTokenSource {
        func accessToken() async throws -> String { "old-token" }
        func refreshedAccessToken() async throws -> String { "new-token" }
    }

    func testARejectedSellerTokenIsRefreshedAndTheCallRetriedOnce() async throws {
        SellStub.route = { request, body in
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if request.url!.path.hasPrefix("/sell/"), bearer == "Bearer old-token" { return Reply(status: 401, body: ["errors": [["errorId": 1001, "message": "Invalid access token"]]]) }
            return self.happyRoute(request, body)
        }
        let (draft, photos) = try draft()
        let result = try await service(tokens: RotatingTokens()).publish(draft: draft, photos: photos, conditionNotes: "")
        XCTAssertEqual(result.listingID, "110591201126")
        let sellerCalls = SellStub.log.filter { ($0.path.hasPrefix("/sell/") && !$0.path.hasPrefix("/sell/metadata/")) || $0.path.contains("/media/") }   // the condition lookup may use the app token
        XCTAssertEqual(sellerCalls.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer old-token")
        XCTAssertEqual(sellerCalls.dropFirst().first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token", "retried once with the refreshed token")
        XCTAssertTrue(sellerCalls.dropFirst(2).allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" || $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" })
    }

    func testAnExpiredPastedTokenIsNotRetriedAndAsksTheSellerToReconnect() async throws {
        SellStub.route = { request, body in
            if request.url!.path.hasPrefix("/sell/") { return Reply(status: 401, body: ["errors": [["errorId": 1001, "message": "Invalid access token"]]]) }
            return self.happyRoute(request, body)
        }
        let (draft, photos) = try draft()
        do { _ = try await service(tokens: StaticEbayTokenSource(token: "stale")).publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() }
        catch let error as EbayAuthError { XCTAssertTrue(error.localizedDescription.contains("pasted")); XCTAssertTrue(error.localizedDescription.contains("Settings")) }
        XCTAssertEqual(SellStub.log.filter { $0.path == "/sell/account/v1/fulfillment_policy" }.count, 1, "the same rejected token is not sent twice for the same request")
        XCTAssertFalse(SellStub.log.contains { $0.path.contains("inventory_item") || $0.path.hasSuffix("/publish") }, "nothing was published")
        XCTAssertTrue(EbaySellService.failure(401, Data()) is EbayAuthError); XCTAssertFalse(EbaySellService.failure(500, Data()) is EbayAuthError)
    }

    @MainActor func testOnlySignInProblemsOfferToOpenSettings() async throws {
        let ebay = FakeEbay(); let flow = try workflow(ebay)
        await flow.prepareEbayListing(0)
        ebay.failure = EbayAuthError(message: "Your eBay sign-in has expired. Reconnect eBay in Settings.")
        await flow.publishToEbay(0)
        XCTAssertEqual(flow.error, "Your eBay sign-in has expired. Reconnect eBay in Settings."); XCTAssertTrue(flow.reconnectNeeded)
        flow.error = nil; flow.reconnectNeeded = false
        ebay.failure = ServiceError.invalid("eBay: Item specific Voltage is missing.")
        await flow.publishToEbay(0)
        XCTAssertNotNil(flow.error); XCTAssertFalse(flow.reconnectNeeded, "ordinary failures keep the plain OK alert")
        flow.reloadServices()   // what the app does when the seller comes back from Settings
        XCTAssertNil(flow.services.ebay, "rebuilt from saved settings (none in tests)")
    }

    func testPublishingSetupStatesDriveWhatTheScreenShows() {
        var services = AppServices()
        XCTAssertEqual(services.ebaySetup, .notConfigured, "nothing set up: the demo button stays")
        services.ebayNeedsSignIn = true
        XCTAssertEqual(services.ebaySetup, .needsSignIn, "set up but signed out: a Connect card, not a missing section")
        services.ebay = FakeEbay()
        XCTAssertEqual(services.ebaySetup, .ready)
    }

    func testTheReadyScreenOpensOnEbayWhenPublishingThereIsPossible() {
        func draft(_ market: Marketplace) -> ListingDraft { ListingDraft(marketplace: market, title: "t", description: "d", price: 1, condition: .good, category: "c", keywords: [], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "", photoOrder: []) }
        let both = [draft(.facebook), draft(.ebay)], onlyFacebook = [draft(.facebook)]
        XCTAssertEqual(ListingReviewView.defaultMarketplace(listings: both, ebaySetup: .ready), .ebay)
        XCTAssertEqual(ListingReviewView.defaultMarketplace(listings: both, ebaySetup: .needsSignIn), .ebay, "the Connect card is reachable without touching the menu")
        XCTAssertEqual(ListingReviewView.defaultMarketplace(listings: both, ebaySetup: .notConfigured), .facebook, "without eBay set up, the order is unchanged")
        XCTAssertEqual(ListingReviewView.defaultMarketplace(listings: onlyFacebook, ebaySetup: .ready), .facebook)
        XCTAssertNil(ListingReviewView.defaultMarketplace(listings: [], ebaySetup: .ready))
    }

    func testSetupReportNamesWhatIsMissing() {
        let none: EbaySetupReport.Loader = { _ in nil }
        XCTAssertEqual(EbaySetupReport.missing(none), ["Sandbox App ID", "Redirect name (RuName)", "Token server URL (or Sandbox Cert ID)"])
        let some: EbaySetupReport.Loader = { $0 == .ebaySandboxRuName ? "Name-SBX-ru" : nil }
        XCTAssertEqual(EbaySetupReport.missing(some), ["Sandbox App ID", "Token server URL (or Sandbox Cert ID)"])
        let all: EbaySetupReport.Loader = { [.ebaySandboxAppID, .ebaySandboxRuName, .ebayAuthProxy].contains($0) ? "x" : nil }
        XCTAssertTrue(EbaySetupReport.missing(all).isEmpty)
    }

    // MARK: Conditions that fit the category

    func testTheAppsConditionsMapToWhatEachCategoryAllows() {
        let books = [2750, 4000, 5000, 6000], tools = [1000, 3000, 5000, 6000, 7000]
        XCTAssertEqual(EbayCondition.choose(.excellent, allowed: books), "LIKE_NEW", "books have no 3000, so Excellent becomes Like New")
        XCTAssertEqual(EbayCondition.choose(.good, allowed: books), "USED_GOOD"); XCTAssertEqual(EbayCondition.choose(.fair, allowed: books), "USED_ACCEPTABLE")
        XCTAssertEqual(EbayCondition.choose(.excellent, allowed: tools), "USED_EXCELLENT"); XCTAssertEqual(EbayCondition.choose(.parts, allowed: tools), "FOR_PARTS_OR_NOT_WORKING")
        XCTAssertNil(EbayCondition.choose(.new, allowed: books), "a category that accepts only used conditions cannot take a new item")
        XCTAssertNil(EbayCondition.choose(.parts, allowed: books))
        XCTAssertEqual(EbayCondition.choose(.good, allowed: []), "USED_GOOD", "unknown: the earlier default")
        XCTAssertEqual(EbayCondition.description(of: books), "Like New, Used Very Good, Used Good, Used Acceptable")
    }

    func testPublishUsesTheConditionTheCategoryAllowsAndExplainsWhenNoneFits() async throws {
        func route(allowed: [String]) -> (URLRequest, Data) -> Reply {
            { request, body in
                if request.url!.path == "/sell/metadata/v1/marketplace/EBAY_US/get_item_condition_policies" {
                    return Reply(body: ["itemConditionPolicies": [["categoryId": "168134", "itemConditions": allowed.map { ["conditionId": $0, "conditionDescription": "x"] }]]])
                }
                return self.happyRoute(request, body)
            }
        }
        SellStub.route = route(allowed: ["2750", "4000", "5000", "6000"])
        var (draft, photos) = try draft(); draft.condition = .excellent
        _ = try await service().publish(draft: draft, photos: photos, conditionNotes: "")
        let put = try XCTUnwrap(SellStub.log.first { $0.method == "PUT" && $0.path.contains("inventory_item") })
        XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: put.body) as? [String: Any]))["condition"] as? String, "LIKE_NEW")
        let lookup = try XCTUnwrap(SellStub.log.first { $0.path.contains("get_item_condition_policies") })
        XCTAssertEqual(URLComponents(url: lookup.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter" }?.value, "categoryIds:{168134}")

        SellStub.log = []; SellStub.route = route(allowed: ["2750", "4000", "5000", "6000"])
        draft.condition = .new
        do { _ = try await service().publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("doesn't accept the condition \"New\"")); XCTAssertTrue(error.localizedDescription.contains("Like New")) }
        XCTAssertFalse(SellStub.log.contains { $0.path.contains("inventory_item") }, "nothing is created when the condition cannot be used")
    }

    func testIfTheMetadataLookupFailsTheEarlierDefaultsApply() async throws {
        SellStub.route = happyRoute   // the lookup answers 404 here
        var (draft, photos) = try draft(); draft.condition = .good
        _ = try await service().publish(draft: draft, photos: photos, conditionNotes: "")
        let put = try XCTUnwrap(SellStub.log.first { $0.method == "PUT" && $0.path.contains("inventory_item") })
        XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: put.body) as? [String: Any]))["condition"] as? String, "USED_GOOD")
    }

    // MARK: Real eBay (live) safeguards

    func testRealEbayPublishingNeedsTheSwitchAndAShipFromZip() async throws {
        SellStub.route = { request, body in
            let path = request.url!.path, method = request.httpMethod ?? ""
            if path == "/sell/inventory/v1/location/SELLPILOT_94107" { return method == "GET" ? Reply(status: 404) : Reply(status: 204) }
            if path.hasSuffix("create_image_from_file") { return Reply(status: 201, headers: ["Location": "https://api.ebay.com/commerce/media/v1_beta/image/IMG1"]) }
            return self.happyRoute(request, body)
        }
        let (draft, photos) = try draft()
        do { _ = try await liveService(allow: false, zip: "94107").publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("isn't enabled")) }
        do { _ = try await liveService(allow: true, zip: "abc").publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("5-digit ZIP")) }
        XCTAssertTrue(SellStub.log.filter { $0.path.hasPrefix("/sell/") }.isEmpty, "nothing reaches eBay while a safeguard stops it")

        let result = try await liveService(allow: true, zip: "94107").publish(draft: draft, photos: photos, conditionNotes: "")
        XCTAssertEqual(result.url.absoluteString, "https://www.ebay.com/itm/110591201126", "a real listing links to real eBay")
        XCTAssertTrue(SellStub.log.allSatisfy { $0.request.url?.host != "api.sandbox.ebay.com" }, "nothing goes to the sandbox")
        let location = try XCTUnwrap(SellStub.log.first { $0.method == "POST" && $0.path == "/sell/inventory/v1/location/SELLPILOT_94107" })
        let address = ((try XCTUnwrap(JSONSerialization.jsonObject(with: location.body) as? [String: Any]))["location"] as? [String: Any])?["address"] as? [String: String]
        XCTAssertEqual(address?["postalCode"], "94107"); XCTAssertEqual(address?["country"], "US")
        let offer = try XCTUnwrap(SellStub.log.first { $0.method == "POST" && $0.path == "/sell/inventory/v1/offer" })
        XCTAssertEqual((try XCTUnwrap(JSONSerialization.jsonObject(with: offer.body) as? [String: Any]))["merchantLocationKey"] as? String, "SELLPILOT_94107")
    }

    func testTheSellersChosenPoliciesAreUsedOnTheOffer() async throws {
        SellStub.route = happyRoute
        var (draft, photos) = try draft()
        draft.ebayFulfillmentPolicyID = "F2"; draft.ebayPaymentPolicyID = "P2"; draft.ebayReturnPolicyID = "R2"
        _ = try await service().publish(draft: draft, photos: photos, conditionNotes: "")
        let offer = try XCTUnwrap(SellStub.log.first { $0.method == "POST" && $0.path == "/sell/inventory/v1/offer" })
        let policies = (try XCTUnwrap(JSONSerialization.jsonObject(with: offer.body) as? [String: Any]))["listingPolicies"] as? [String: String]
        XCTAssertEqual(policies, ["fulfillmentPolicyId": "F2", "paymentPolicyId": "P2", "returnPolicyId": "R2"])
    }

    func testPoliciesAreListedByNameAndOnlyTheSandboxCreatesDefaults() async throws {
        SellStub.route = { request, body in
            let path = request.url!.path, method = request.httpMethod ?? ""
            if method == "GET", path == "/sell/account/v1/fulfillment_policy" { return Reply(body: ["fulfillmentPolicies": [["fulfillmentPolicyId": "F1", "name": "Standard shipping"], ["fulfillmentPolicyId": "F2", "name": "Express"]]]) }
            if method == "GET", path == "/sell/account/v1/payment_policy" { return Reply(body: ["paymentPolicies": [["paymentPolicyId": "P1", "name": "Managed payments"]]]) }
            if method == "GET", path == "/sell/account/v1/return_policy" { return Reply(body: ["returnPolicies": [["returnPolicyId": "R1", "name": "30-day returns"]]]) }
            return self.happyRoute(request, body)
        }
        let listed = try await service().policies()
        XCTAssertEqual(listed.fulfillment.map(\.name), ["Standard shipping", "Express"]); XCTAssertEqual(listed.payment.first?.id, "P1"); XCTAssertEqual(listed.returns.first?.name, "30-day returns")

        SellStub.log = []
        SellStub.route = { request, body in
            let path = request.url!.path, method = request.httpMethod ?? ""
            if method == "GET", path.hasSuffix("_policy") { return Reply(body: [String: Any]()) }
            return self.happyRoute(request, body)
        }
        let real = try await liveService(allow: true, zip: "94107").policies()
        XCTAssertEqual(real, EbaySellerPolicies(), "a real seller with no policies gets none made up for them")
        XCTAssertFalse(SellStub.log.contains { $0.method == "POST" && $0.path.hasSuffix("_policy") })
    }

    @MainActor func testPoliciesDefaultToTheFirstAndKeepAValidChoice() async throws {
        let ebay = FakeEbay(); let flow = try workflow(ebay)
        await flow.loadEbayPolicies(0)
        XCTAssertEqual(flow.item.listings[0].ebayFulfillmentPolicyID, "F1"); XCTAssertEqual(flow.item.listings[0].ebayPaymentPolicyID, "P1"); XCTAssertEqual(flow.item.listings[0].ebayReturnPolicyID, "R1")
        flow.item.listings[0].ebayFulfillmentPolicyID = "F2"
        await flow.loadEbayPolicies(0); XCTAssertEqual(flow.item.listings[0].ebayFulfillmentPolicyID, "F2", "a valid choice is kept")
        flow.item.listings[0].ebayFulfillmentPolicyID = "GONE"
        await flow.loadEbayPolicies(0); XCTAssertEqual(flow.item.listings[0].ebayFulfillmentPolicyID, "F1", "a policy that no longer exists is replaced")
    }

    func testTheConfirmationShowsEverythingAndWarnsOnlyForRealListings() {
        var draft = ListingDraft(marketplace: .ebay, title: "DEWALT DCF887B Impact Driver (tool only)", description: "d", price: 49, condition: .good, category: "c", keywords: [], itemSpecifics: [:], shippingNotes: "", localPickupNotes: "", photoOrder: [UUID(), UUID(), UUID()])
        draft.ebayCategoryName = "Impact Drivers"; draft.ebayFulfillmentPolicyID = "F2"; draft.ebayPaymentPolicyID = "P1"; draft.ebayReturnPolicyID = "R1"
        let policies = EbaySellerPolicies(fulfillment: [EbayPolicy(id: "F2", name: "Express")], payment: [EbayPolicy(id: "P1", name: "Managed payments")], returns: [EbayPolicy(id: "R1", name: "30-day returns")])
        let live = EbayPublishCard.confirmationSummary(draft: draft, photoCount: 3, policies: policies, live: true)
        for expected in ["DEWALT DCF887B Impact Driver (tool only)", "$49", "Good", "3 photos", "Impact Drivers", "Express", "Managed payments", "30-day returns", "LIVE listing", "fees"] { XCTAssertTrue(live.contains(expected), expected) }
        let sandbox = EbayPublishCard.confirmationSummary(draft: draft, photoCount: 1, policies: policies, live: false)
        XCTAssertTrue(sandbox.contains("1 photo\n") || sandbox.contains("1 photo"), "singular"); XCTAssertFalse(sandbox.contains("LIVE")); XCTAssertTrue(sandbox.contains("Sandbox only"))
    }

    func testLiveSetupChecks() {
        XCTAssertTrue(LiveSettings.isValidZip("94107")); XCTAssertFalse(LiveSettings.isValidZip("9410")); XCTAssertFalse(LiveSettings.isValidZip("94107-1234")); XCTAssertFalse(LiveSettings.isValidZip(""))
        let none: EbaySetupReport.Loader = { _ in nil }
        XCTAssertEqual(EbaySetupReport.missing(live: true, zip: "", none), ["Production App ID", "Production redirect name (RuName)", "Ship-from ZIP code", "Token server URL (or Production Cert ID)"])
        let done: EbaySetupReport.Loader = { [.ebayAppID, .ebayRuName, .ebayAuthProxy].contains($0) ? "x" : nil }
        XCTAssertTrue(EbaySetupReport.missing(live: true, zip: "94107", done).isEmpty)
        XCTAssertEqual(EbaySetupReport.missing(live: true, zip: "oops", done), ["Ship-from ZIP code"])
    }

    func testThePhotoAddressMustBeEbaysOwnBeforeTheSellersTokenIsSentThere() async throws {
        for bad in ["https://evil.example.com/image/1", "http://api.ebay.com/commerce/media/v1_beta/image/1", "https://api.ebay.com.evil.example/image/1"] {
            SellStub.log = []
            SellStub.route = { request, body in
                request.url!.path.hasSuffix("create_image_from_file") ? Reply(status: 201, headers: ["Location": bad]) : self.happyRoute(request, body)
            }
            let (draft, photos) = try draft()
            do { _ = try await service().publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail(bad) }
            catch { XCTAssertTrue(error.localizedDescription.contains("unexpected photo address"), bad) }
            XCTAssertFalse(SellStub.log.contains { $0.request.url?.host?.contains("evil") == true }, "the token never leaves eBay's domain")
            XCTAssertFalse(SellStub.log.contains { $0.path.contains("inventory_item") }, "nothing is created")
        }
    }
}
