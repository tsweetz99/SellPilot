import XCTest
@testable import SellPilot

private final class HostedStub: URLProtocol {
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

final class HostedAITests: XCTestCase {
    private var root: URL!
    private let installKey = "0123456789abcdef0123456789abcdef"
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        PhotoStorage.shared = PhotoStorage(root: root)
        HostedStub.requests = []; HostedStub.bodies = []; HostedStub.handler = nil
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private var session: URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HostedStub.self]; return URLSession(configuration: config) }
    private func identification() -> HostedIdentificationService {
        HostedIdentificationService(configuration: .init(endpoint: URL(string: "https://example.test/api/ai")!, installKey: { self.installKey }, retryDelay: .milliseconds(1)), session: session)
    }
    private func facts() -> HostedItemFactsService {
        HostedItemFactsService(configuration: .init(endpoint: URL(string: "https://example.test/api/ai")!, installKey: { self.installKey }, retryDelay: .milliseconds(1)), session: session)
    }
    private func photos(_ count: Int) throws -> [SellItemPhoto] {
        let jpeg = try XCTUnwrap(PhotoImport.normalized(PhotoImport.demoPhoto()))
        return try (0..<count).map { _ in try SellItemPhoto(originalData: jpeg, previewData: jpeg) }
    }
    private func answer(_ name: String, _ input: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: ["content": [["type": "tool_use", "name": name, "input": input]]]) }
    private func refusal(_ error: String, _ message: String) -> Data { try! JSONSerialization.data(withJSONObject: ["error": error, "message": message]) }
    private let full: [String: Any] = ["title": "Milwaukee M18 Fuel Drill", "brand": "Milwaukee", "model": "2804-20", "category": "Tools", "subcategory": "Power tools", "color": "Red", "condition": "Good", "confidence": 0.9]

    func testIdentificationSendsOnlyPhotosAndTheInstallCode() async throws {
        HostedStub.handler = { _ in (200, self.answer("report_identification", self.full)) }
        let result = try await identification().identify(photos: photos(8))
        XCTAssertEqual(result.product.brand, "Milwaukee"); XCTAssertEqual(result.provider, "SellPilot AI"); XCTAssertFalse(result.isSimulated)

        let request = try XCTUnwrap(HostedStub.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/ai"); XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-sellpilot-install"), installKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key")); XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-version"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: HostedStub.bodies[0]) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["task", "photos"], "no prompt, model or instructions are sent; the server owns those")
        XCTAssertEqual(body["task"] as? String, "identify")
        let sent = try XCTUnwrap(body["photos"] as? [[String: String]])
        XCTAssertEqual(sent.count, 6, "at most six photos")
        let first = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(sent[0]["data"])))
        XCTAssertEqual(Array(first.prefix(3)), [0xFF, 0xD8, 0xFF], "JPEG")
    }

    func testTheSellerIsToldWhereTheirPhotosGo() {
        let note = identification().disclosure ?? ""
        XCTAssertTrue(note.contains("SellPilot's AI service")); XCTAssertTrue(note.contains("Anthropic")); XCTAssertTrue(note.contains("not stored"))
    }

    func testTheServersOwnWordsAreShownForRefusals() async throws {
        for (status, error, message) in [(429, "rate_limited", "You've reached today's limit for AI identification. Try again tomorrow, or enter the details yourself."),
                                         (503, "ai_unavailable", "AI identification is paused right now. You can still enter the item's details yourself."),
                                         (422, "upstream_rejected", "The photos could not be processed. Try clearer or fewer photos.")] {
            HostedStub.requests = []; HostedStub.bodies = []
            HostedStub.handler = { _ in (status, self.refusal(error, message)) }
            do { _ = try await identification().identify(photos: photos(1)); XCTFail("should fail") }
            catch { XCTAssertEqual(error.localizedDescription, message, "status \(status)") }
        }
    }

    func testOnlyBriefOutagesAreRetried() async throws {
        for (status, expected) in [(429, 1), (504, 1), (422, 1), (502, 2), (503, 2)] {
            HostedStub.requests = []; HostedStub.bodies = []
            HostedStub.handler = { _ in (status, self.refusal("x", "nope")) }
            _ = try? await identification().identify(photos: photos(1))
            XCTAssertEqual(HostedStub.requests.count, expected, "status \(status)")
        }
    }

    func testAnUnverifiedInstallGetsAClearMessage() async throws {
        HostedStub.handler = { _ in (401, Data("{}".utf8)) }
        do { _ = try await identification().identify(photos: photos(1)); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not be verified")) }
    }

    func testAnUnexplainedFailureNeverShowsABareStatusCode() async throws {
        for status in [404, 500, 502, 504] {
            HostedStub.handler = { _ in (status, Data("<html>Not Found</html>".utf8)) }
            do { _ = try await identification().identify(photos: photos(1)); XCTFail() }
            catch { XCTAssertTrue(error.localizedDescription.contains("AI service isn't available right now"), "status \(status): \(error.localizedDescription)") }
        }
    }

    func testFactsSendOnlyTheSellersDescription() async throws {
        HostedStub.handler = { _ in (200, self.answer("report_facts", ["brand": "DEWALT", "battery_included": "no", "other": ["Speed": "3 speed"]])) }
        var item = SellItem(); item.title = "DEWALT DCF887B"; item.brand = "DEWALT"; item.sellerNotes = "Tool only"
        let result = try await facts().facts(for: item)
        XCTAssertEqual(result["battery_included"], "no"); XCTAssertEqual(result["speed"], "3 speed")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: HostedStub.bodies[0]) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["task", "description"]); XCTAssertEqual(body["task"] as? String, "facts")
        XCTAssertEqual(body["description"] as? String, ClaudeItemFactsService.describe(item))
        XCTAssertTrue((body["description"] as? String ?? "").contains("Seller notes: Tool only"))
        XCTAssertEqual(HostedStub.requests[0].value(forHTTPHeaderField: "x-sellpilot-install"), installKey)
    }

    func testConsentIsRememberedOnceGiven() {
        let prior = AIConsent.given; defer { AIConsent.given = prior }
        AIConsent.given = false; XCTAssertFalse(AIConsent.given)
        AIConsent.given = true; XCTAssertTrue(AIConsent.given)
    }

    // MARK: The server keeps its own copy of the instructions. These fail if the two copies drift apart.

    private func serverPrompts() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("server/ebay-auth/lib/aiPrompts.mjs"), encoding: .utf8)
    }
    private func jsList(_ name: String, in source: String) throws -> [String] {
        let match = try XCTUnwrap(source.range(of: "export const \(name) = \\[(.*?)\\];", options: .regularExpression))
        return source[match].components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
    }
    private func jsTemplate(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "export const \(name) = `"))
        let end = try XCTUnwrap(source.range(of: "`;", range: start.upperBound..<source.endIndex))
        return source[start.upperBound..<end.lowerBound].replacingOccurrences(of: "\\\n", with: "")
    }

    func testServerAndAppAgreeOnCategoriesConditionsAndFacts() throws {
        let source = try serverPrompts()
        XCTAssertEqual(try jsList("CATEGORIES", in: source), SellItem.categories)
        XCTAssertEqual(try jsList("CONDITIONS", in: source), ItemCondition.allCases.map(\.rawValue))
        XCTAssertEqual(try jsList("FACT_NAMES", in: source), ClaudeItemFactsService.factNames)
    }

    func testServerAndAppAgreeOnTheInstructions() throws {
        let source = try serverPrompts()
        XCTAssertEqual(try jsTemplate("IDENTIFY_SYSTEM", in: source), ClaudeIdentificationService.systemPrompt)
        XCTAssertEqual(try jsTemplate("FACTS_SYSTEM", in: source), ClaudeItemFactsService.systemPrompt)
    }
}
