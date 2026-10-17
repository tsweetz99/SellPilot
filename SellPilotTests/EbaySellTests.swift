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
        return EbaySellService(configuration: .init(environment: environment, credentials: .init(appID: "app", certID: "cert"), userToken: "user-token"), session: URLSession(configuration: config))
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
        do { _ = try await service().publish(draft: draft, photos: photos, conditionNotes: ""); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "eBay: Item specific Voltage is missing. Second problem.") }
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
        var aspectList = [EbayAspect(name: "Brand", required: true, selectionOnly: false, multiValue: false, values: []), EbayAspect(name: "Voltage", required: true, selectionOnly: false, multiValue: false, values: [])]
        func suggestCategories(query: String) async throws -> [EbayCategory] { [EbayCategory(id: "168134", name: "Impact Drivers", path: "Tools › Impact Drivers"), EbayCategory(id: "1", name: "Other", path: "Other")] }
        func aspects(for categoryID: String) async throws -> [EbayAspect] { aspectList }
        func publish(draft: ListingDraft, photos: [SellItemPhoto], conditionNotes: String) async throws -> EbayPublishResult { published.append(draft); return EbayPublishResult(offerID: "O", listingID: "L", url: URL(string: "https://sandbox.ebay.com/itm/L")!) }
        func withdraw(offerID: String) async throws {}
    }
    private struct FakeSpecifics: ItemSpecificsService { func fill(item: SellItem, aspects: [EbayAspect]) async throws -> [String: String] { ["Voltage": "20V"] } }

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
        XCTAssertEqual(flow.item.listings[0].ebayCategoryID, "168134"); XCTAssertEqual(flow.item.listings[0].itemSpecifics["Brand"], "DEWALT")
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

    // MARK: Specifics filler

    func testSpecificsFillerListsAllowedValuesAndDropsInvalidAnswers() async throws {
        SellStub.route = { _, _ in Reply(body: ["content": [["type": "tool_use", "name": "report_specifics", "input": ["values": [["name": "Battery Included", "value": "no"], ["name": "Voltage", "value": "20V"], ["name": "Color", "value": "Chartreuse"], ["name": "Brand", "value": NSNull()]]]]]]) }
        let aspects = [EbayAspect(name: "Battery Included", required: true, selectionOnly: true, multiValue: false, values: ["Yes", "No"]), EbayAspect(name: "Voltage", required: true, selectionOnly: false, multiValue: false, values: []),
                       EbayAspect(name: "Color", required: true, selectionOnly: true, multiValue: false, values: ["Black"]), EbayAspect(name: "Brand", required: true, selectionOnly: false, multiValue: false, values: [])]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SellStub.self]
        var item = SellItem(); item.title = "DEWALT DCF887B"; item.sellerNotes = "Tool only"
        let result = try await ClaudeSpecificsFiller(configuration: .init(apiKey: "k"), session: URLSession(configuration: config)).fill(item: item, aspects: aspects)
        XCTAssertEqual(result, ["Battery Included": "No", "Voltage": "20V"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SellStub.log[0].body) as? [String: Any])
        let prompt = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? String)
        XCTAssertTrue(prompt.contains("Battery Included (allowed: Yes | No)")); XCTAssertTrue(prompt.contains("Tool only")); XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5-20251001")
    }
}
