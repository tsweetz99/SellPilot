import XCTest
@testable import SellPilot

private final class PurchaseStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            Self.bodies.append(data)
        } else if let body = request.httpBody { Self.bodies.append(body) }
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// An identification service that always says the seller is out of analyses.
private struct OutOfAnalyses: ProductIdentificationService {
    func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification { throw HostedAIError(message: "You've used your free analyses.") }
}

final class PurchasesTests: XCTestCase {
    private var root: URL!
    private let installKey = "0123456789abcdef0123456789abcdef"
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        PhotoStorage.shared = PhotoStorage(root: root)
        PurchaseStub.requests = []; PurchaseStub.bodies = []; PurchaseStub.handler = nil
        EntitlementCache.jws = nil
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); EntitlementCache.jws = nil }

    private var session: URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PurchaseStub.self]; return URLSession(configuration: config) }
    private func photos(_ count: Int) throws -> [SellItemPhoto] {
        let jpeg = try XCTUnwrap(PhotoImport.normalized(PhotoImport.demoPhoto()))
        return try (0..<count).map { _ in try SellItemPhoto(originalData: jpeg, previewData: jpeg) }
    }
    private func hostedIdentification() -> HostedIdentificationService {
        HostedIdentificationService(configuration: .init(endpoint: URL(string: "https://example.test/api/ai")!, installKey: { self.installKey }, retryDelay: .milliseconds(1)), session: session)
    }
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private let identified: [String: Any] = ["title": "Milwaukee M18 Fuel Drill", "brand": "Milwaukee", "model": "2804-20", "category": "Tools", "subcategory": "Power tools", "color": "Red", "condition": "Good", "confidence": 0.9]

    // MARK: The app and the server must agree on what is for sale. These fail if the two lists drift apart.

    private func serverSource(_ file: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("server/ebay-auth/lib/\(file)"), encoding: .utf8)
    }

    func testTheServerSellsTheSameProductsTheAppShows() throws {
        let source = try serverSource("products.mjs")
        for id in PlusProduct.all { XCTAssertTrue(source.contains("\"\(id)\""), "\(id) is missing from products.mjs") }
        XCTAssertEqual(PlusProduct.all.count, 3)
        XCTAssertEqual(source.components(separatedBy: "kind: \"subscription\"").count - 1, PlusProduct.subscriptions.count)
    }

    func testTheNumbersTheAppPromisesAreTheNumbersTheServerGives() throws {
        let source = try serverSource("products.mjs")
        XCTAssertTrue(source.contains("freeAnalyses: \(PlusProduct.freeAnalyses),"), "free analyses differ from the server")
        XCTAssertTrue(source.contains("plusPerPeriod: \(PlusProduct.plusPerPeriod),"), "Plus analyses differ from the server")
        XCTAssertTrue(source.contains("credits: \(PlusProduct.packSize)"), "pack size differs from the server")
    }

    func testTheStoreKitTestFileHasTheSameProductsAndPrices() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: repo.appendingPathComponent("SellPilot.storekit"), encoding: .utf8)
        for id in PlusProduct.all { XCTAssertTrue(file.contains("\"\(id)\""), "\(id) is missing from SellPilot.storekit") }
        for price in ["4.99", "34.99", "2.99"] { XCTAssertTrue(file.contains("\"displayPrice\" : \"\(price)\""), "price \(price) is missing from SellPilot.storekit") }
    }

    // MARK: What the seller sees

    func testAllowanceIsReadFromTheServersAnswerAndDescribedPlainly() throws {
        let body = json(["content": [], "allowance": ["free": 3, "credits": 0, "plus": NSNull()]])
        let allowance = try XCTUnwrap(AIAllowance.parse(body))
        XCTAssertEqual(allowance, AIAllowance(free: 3, credits: 0, plus: nil)); XCTAssertEqual(allowance.available, 3)
        XCTAssertEqual(allowance.summary, "3 free analyses left")
        XCTAssertEqual(AIAllowance(free: 1, credits: 0, plus: nil).summary, "1 free analysis left")
        XCTAssertEqual(AIAllowance(free: 0, credits: 24, plus: nil).summary, "24 pack analyses left")
        XCTAssertEqual(AIAllowance(free: 0, credits: 0, plus: nil).summary, "No analyses left")
        let plus = AIAllowance(free: 5, credits: 0, plus: .init(remaining: 52, limit: 60, renews: 1_800_000_000_000))
        XCTAssertEqual(plus.available, 57); XCTAssertTrue(plus.summary.hasPrefix("52 of 60 Plus analyses left"))
        XCTAssertNil(AIAllowance.parse(Data("not json".utf8))); XCTAssertNil(AIAllowance.parse(json(["content": []])))
    }

    @MainActor func testAnalysesReportWhatIsLeftSoTheScreenStaysRight() async throws {
        PurchaseStub.handler = { _ in (200, self.json(["content": [["type": "tool_use", "name": "report_identification", "input": self.identified]], "allowance": ["free": 4, "credits": 0]])) }
        _ = try await hostedIdentification().identify(photos: photos(2))
        XCTAssertEqual(PurchaseStore.shared.allowance, AIAllowance(free: 4, credits: 0, plus: nil))
    }

    // MARK: What goes to the server

    func testPlusIsProvedWithAppleSignedRecordOnlyWhenOwned() throws {
        let without = try hostedIdentification().makeRequest(photos: photos(1))
        XCTAssertNil(without.value(forHTTPHeaderField: "x-sellpilot-entitlement"))
        EntitlementCache.jws = "header.payload.signature"
        let with = try hostedIdentification().makeRequest(photos: photos(1))
        XCTAssertEqual(with.value(forHTTPHeaderField: "x-sellpilot-entitlement"), "header.payload.signature")
        XCTAssertEqual(with.value(forHTTPHeaderField: "x-sellpilot-install"), installKey)
    }

    func testAskingWhatIsLeftSendsTheInstallCodeAndPlusProof() throws {
        let client = AllowanceClient(endpoint: URL(string: "https://example.test/api/ai/account")!, installKey: { self.installKey }, entitlement: { "a.b.c" }, session: session)
        let request = try client.makeRequest()
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sellpilot-install"), installKey); XCTAssertEqual(request.value(forHTTPHeaderField: "x-sellpilot-entitlement"), "a.b.c")
    }

    func testRedeemingAPackSendsOnlyTheSignedTransaction() async throws {
        PurchaseStub.handler = { _ in (200, self.json(["added": 25, "allowance": ["free": 0, "credits": 25, "plus": NSNull()]])) }
        let client = AllowanceClient(endpoint: URL(string: "https://example.test/api/ai/account")!, installKey: { self.installKey }, entitlement: { nil }, session: session)
        let allowance = try await client.redeem("signed.transaction.jws")
        XCTAssertEqual(allowance.credits, 25)
        let request = try XCTUnwrap(PurchaseStub.requests.first)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.value(forHTTPHeaderField: "x-sellpilot-entitlement"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: PurchaseStub.bodies[0]) as? [String: Any])
        XCTAssertEqual(body as? [String: String], ["transaction": "signed.transaction.jws"])
    }

    func testTheStatusAnswerSaysWhetherThePaywallIsOn() async throws {
        let client = AllowanceClient(endpoint: URL(string: "https://example.test/api/ai/account")!, installKey: { self.installKey }, entitlement: { nil }, session: session)
        PurchaseStub.handler = { _ in (200, self.json(["paywall": false, "allowance": ["free": 5, "credits": 0]])) }
        let off = try await client.status()
        XCTAssertFalse(off.paywall); XCTAssertEqual(off.allowance.free, 5)
        PurchaseStub.handler = { _ in (200, self.json(["allowance": ["free": 5, "credits": 0]])) }
        let unspecified = try await client.status()
        XCTAssertTrue(unspecified.paywall, "an answer that does not say is treated as the paywall being on")
    }

    func testAFailedRedeemSaysSoInPlainWordsAndNothingIsLost() async throws {
        PurchaseStub.handler = { _ in (503, self.json(["error": "unavailable", "message": "Purchases are unavailable right now. Try again shortly; nothing has been lost."])) }
        let client = AllowanceClient(endpoint: URL(string: "https://example.test/api/ai/account")!, installKey: { self.installKey }, entitlement: { nil }, session: session)
        do { _ = try await client.redeem("x"); XCTFail("should have thrown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("nothing has been lost")) }
    }

    // MARK: Running out

    @MainActor func testOutOfAnalysesIsAPromptToChooseAPlanNotAFailure() async throws {
        PurchaseStore.shared.record(AIAllowance(free: 1, credits: 0, plus: nil))
        PurchaseStub.handler = { _ in (402, self.json(["error": "allowance_exhausted", "message": "You've used your free analyses. Choose a plan or a pack.", "allowance": ["free": 0, "credits": 0]])) }
        do { _ = try await hostedIdentification().identify(photos: photos(1)); XCTFail("should have thrown") }
        catch let error as HostedAIError { XCTAssertEqual(error.message, "You've used your free analyses. Choose a plan or a pack."); XCTAssertEqual(error.allowance, AIAllowance(free: 0, credits: 0, plus: nil)) }
        XCTAssertEqual(PurchaseStub.requests.count, 1, "an empty allowance is not retried")
        XCTAssertEqual(PurchaseStore.shared.allowance, AIAllowance(free: 0, credits: 0, plus: nil), "the app's count is corrected, so closing the plans does not start another analysis")
    }

    func testOnlyA402MeansOutOfAnalyses() {
        XCTAssertNil(HostedAI.failure(status: 429, body: Data())); XCTAssertNil(HostedAI.failure(status: 503, body: Data())); XCTAssertNil(HostedAI.failure(status: 401, body: Data()))
        XCTAssertNotNil(HostedAI.failure(status: 402, body: Data()), "even a bare 402 gets a sensible message")
        XCTAssertTrue((HostedAI.failure(status: 402, body: Data()) as? HostedAIError)?.message.contains("free analyses") ?? false)
    }

    @MainActor func testTheWorkflowShowsThePlansInsteadOfAnErrorAndKeepsThePhotos() async throws {
        var services = AppServices(); services.identification = OutOfAnalyses()
        let container = try ModelContainerFactory.inMemory()
        let workflow = SellingWorkflow(item: SellItem(), store: ItemStore(context: container.mainContext), services: services)
        workflow.item.photos = try photos(1)
        await workflow.advance()
        XCTAssertEqual(workflow.paywallReason, "You've used your free analyses.")
        XCTAssertNil(workflow.error, "no alert")
        XCTAssertFalse(workflow.identificationFailed, "not shown as a failed identification")
        XCTAssertEqual(workflow.item.workflowStep, 0); XCTAssertEqual(workflow.item.photos.count, 1)
        XCTAssertFalse(workflow.busy)
    }

    @MainActor func testEnteringDetailsByHandStillWorksWhenOutOfAnalyses() async throws {
        var services = AppServices(); services.identification = OutOfAnalyses()
        let container = try ModelContainerFactory.inMemory()
        let workflow = SellingWorkflow(item: SellItem(), store: ItemStore(context: container.mainContext), services: services)
        workflow.item.photos = try photos(1)
        await workflow.advance()
        workflow.paywallReason = nil
        workflow.skipIdentification()
        XCTAssertEqual(workflow.item.workflowStep, 1, "manual entry is always free")
    }

    func testTheTermsLinkIsApplesStandardAgreement() {
        XCTAssertEqual(PlusProduct.termsURL.host, "www.apple.com"); XCTAssertTrue(PlusProduct.termsURL.path.contains("stdeula"))
    }
}

/// A throwaway store for tests that need an `ItemStore`.
import SwiftData
private enum ModelContainerFactory {
    @MainActor static func inMemory() throws -> ModelContainer {
        try ModelContainer(for: StoredSellItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
}
