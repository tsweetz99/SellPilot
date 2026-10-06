import XCTest
@testable import SellPilot

private final class StubProtocol: URLProtocol {
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

final class IdentificationTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        PhotoStorage.shared = PhotoStorage(root: root)
        StubProtocol.requests = []; StubProtocol.bodies = []; StubProtocol.handler = nil
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func service(retryDelay: Duration = .milliseconds(1)) -> ClaudeIdentificationService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return ClaudeIdentificationService(configuration: .init(apiKey: "test-key", retryDelay: retryDelay), session: URLSession(configuration: config))
    }
    private func photos(_ count: Int) throws -> [SellItemPhoto] {
        let jpeg = try XCTUnwrap(PhotoImport.normalized(PhotoImport.demoPhoto()))
        return try (0..<count).map { _ in try SellItemPhoto(originalData: jpeg, previewData: jpeg) }
    }
    private func reply(_ input: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "tool_use", "name": "report_identification", "input": input]]])
    }
    private let full: [String: Any] = [
        "title": "Milwaukee M18 Fuel Drill", "brand": "Milwaukee", "model": "2804-20", "model_number": "2804-20", "category": "Tools",
        "subcategory": "Power tools", "color": "Red / black", "condition": "Good", "condition_notes": "Scuffs on housing", "confidence": 0.93,
        "visible_text": ["M18 FUEL", "2804-20"], "attributes": ["Voltage": "18V"],
        "alternates": [["title": "Milwaukee M18 Hammer Drill", "brand": "Milwaukee", "model": "2804-20", "category": "Tools"]],
    ]

    func testMapsStructuredReplyAndSendsExpectedRequest() async throws {
        StubProtocol.handler = { _ in (200, self.reply(self.full)) }
        let result = try await service().identify(photos: photos(8))
        XCTAssertEqual(result.product.brand, "Milwaukee"); XCTAssertEqual(result.possibleModelNumber, "2804-20")
        XCTAssertEqual(result.detectedCondition, .good); XCTAssertEqual(result.confidenceScore, 0.93, accuracy: 0.001)
        XCTAssertEqual(result.recognizedAttributes["Voltage"], "18V"); XCTAssertEqual(result.recognizedAttributes["Text seen in photos"], "M18 FUEL · 2804-20")
        XCTAssertEqual(result.alternateMatches.count, 1); XCTAssertFalse(result.isSimulated)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key"); XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        XCTAssertEqual((body["tool_choice"] as? [String: String])?["name"], "report_identification")
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])
        XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, 6, "capped at maxPhotos")
    }

    func testSinglePhotoConfidenceIsCappedAndUnknownCategoryBecomesOther() async throws {
        var input = full; input["confidence"] = 0.99; input["category"] = "Spaceships"
        StubProtocol.handler = { _ in (200, self.reply(input)) }
        let result = try await service().identify(photos: photos(1))
        XCTAssertEqual(result.confidenceScore, 0.8, accuracy: 0.001); XCTAssertEqual(result.product.category, "Other")
    }

    func testRejectedKeyGivesActionableMessageWithoutRetry() async throws {
        StubProtocol.handler = { _ in (401, Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8)) }
        do { _ = try await service().identify(photos: photos(1)); XCTFail("expected error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("API key")) }
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testRateLimitRetriesOnceThenSucceeds() async throws {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return calls == 1 ? (429, Data()) : (200, self.reply(self.full)) }
        let result = try await service().identify(photos: photos(2))
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.product.title, "Milwaukee M18 Fuel Drill")
    }

    func testMissingToolCallAndEmptyTitleFailClearly() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"content":[{"type":"text","text":"hello"}]}"#.utf8)) }
        do { _ = try await service().identify(photos: photos(1)); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not be read")) }
        var input = full; input["title"] = "  "
        StubProtocol.handler = { _ in (200, self.reply(input)) }
        do { _ = try await service().identify(photos: photos(1)); XCTFail() } catch { XCTAssertTrue(error.localizedDescription.contains("could not be identified")) }
    }

    func testNoPhotosIsRejectedBeforeAnyNetworkCall() async {
        StubProtocol.handler = { _ in (200, Data()) }
        do { _ = try await service().identify(photos: []); XCTFail() } catch { XCTAssertTrue(StubProtocol.requests.isEmpty) }
    }
}
