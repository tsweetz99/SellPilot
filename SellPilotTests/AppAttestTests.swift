import XCTest
import CryptoKit
@testable import SellPilot

private final class AttestStub: URLProtocol {
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
        } else { Self.bodies.append(request.httpBody ?? Data()) }
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakeAttestService: AttestKeyService, @unchecked Sendable {
    var isSupported = true
    var assertionFails = false
    var attestedHashes: [Data] = [], assertedHashes: [Data] = []
    var keysMade = 0
    func generateKey() async throws -> String { keysMade += 1; return "key-\(keysMade)" }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { attestedHashes.append(clientDataHash); return Data("attestation-for-\(keyID)".utf8) }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        if assertionFails { throw NSError(domain: "fake", code: 1) }
        assertedHashes.append(clientDataHash); return Data("assertion-\(assertedHashes.count)".utf8)
    }
}

/// Signs by numbering the requests, so a test can see that every attempt was signed on its own.
private final class CountingSigner: RequestSigner, @unchecked Sendable {
    var count = 0
    func sign(_ request: URLRequest) async -> URLRequest { count += 1; var r = request; r.setValue("signature-\(count)", forHTTPHeaderField: "x-test-signature"); return r }
    func reset() async {}
}

final class AppAttestTests: XCTestCase {
    private let endpoint = URL(string: "https://example.test/api/attest")!
    private let installKey = "0123456789abcdef0123456789abcdef"
    private var defaults: UserDefaults!
    private var suite = ""
    override func setUp() {
        suite = "attest-tests-\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite)
        AttestStub.requests = []; AttestStub.bodies = []; AttestStub.handler = nil
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private var session: URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AttestStub.self]; return URLSession(configuration: config) }
    private func signer(_ service: FakeAttestService, enabled: Bool = true) -> AppAttestSigner {
        AppAttestSigner(service: service, endpoint: endpoint, installKey: { self.installKey }, session: session, defaults: defaults, enabled: enabled)
    }
    private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func serverAccepts() { AttestStub.handler = { request in request.httpMethod == "GET" ? (200, self.json(["challenge": "challenge-123"])) : (200, self.json(["ok": true])) } }
    private func aiRequest(_ body: String = #"{"task":"identify"}"#) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://example.test/api/ai")!); r.httpMethod = "POST"; r.httpBody = Data(body.utf8); return r
    }

    func testWithoutAppAttestTheRequestIsLeftAlone() async {
        let unsupported = FakeAttestService(); unsupported.isSupported = false
        serverAccepts()
        let original = aiRequest()
        let a = await signer(unsupported).sign(original), b = await signer(FakeAttestService(), enabled: false).sign(original)
        for result in [a, b] { XCTAssertNil(result.value(forHTTPHeaderField: AppAttestSigner.keyHeader)); XCTAssertNil(result.value(forHTTPHeaderField: AppAttestSigner.assertionHeader)); XCTAssertEqual(result.httpBody, original.httpBody) }
        XCTAssertTrue(AttestStub.requests.isEmpty, "nothing is sent to the server when there is no App Attest")
    }

    func testTheFirstRequestRegistersTheDeviceKeyThenCarriesProof() async throws {
        serverAccepts()
        let service = FakeAttestService()
        let signed = await signer(service).sign(aiRequest())

        XCTAssertEqual(AttestStub.requests.count, 2, "one challenge request and one registration")
        let challengeRequest = AttestStub.requests[0], registration = AttestStub.requests[1]
        XCTAssertEqual(challengeRequest.httpMethod, "GET"); XCTAssertEqual(challengeRequest.value(forHTTPHeaderField: "x-sellpilot-install"), installKey)
        XCTAssertEqual(registration.httpMethod, "POST"); XCTAssertEqual(registration.value(forHTTPHeaderField: "x-sellpilot-install"), installKey)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: AttestStub.bodies[1]) as? [String: String])
        XCTAssertEqual(body["keyId"], "key-1"); XCTAssertEqual(body["challenge"], "challenge-123")
        XCTAssertEqual(body["attestation"], Data("attestation-for-key-1".utf8).base64EncodedString())
        XCTAssertEqual(service.attestedHashes, [Data(SHA256.hash(data: Data("challenge-123".utf8)))], "Apple is asked to vouch for the key together with the server's challenge")

        XCTAssertEqual(signed.value(forHTTPHeaderField: AppAttestSigner.keyHeader), "key-1")
        XCTAssertEqual(signed.value(forHTTPHeaderField: AppAttestSigner.assertionHeader), Data("assertion-1".utf8).base64EncodedString())
        XCTAssertEqual(service.assertedHashes, [Data(SHA256.hash(data: Data(#"{"task":"identify"}"#.utf8)))], "the signature covers the exact request body")
        XCTAssertEqual(defaults.string(forKey: "appAttestKeyID"), "key-1")
        XCTAssertEqual(signed.httpBody, aiRequest().httpBody, "the request itself is not changed")
    }

    func testLaterRequestsReuseTheKeyWithoutContactingTheServerAgain() async {
        serverAccepts()
        let service = FakeAttestService(), s = signer(service)
        _ = await s.sign(aiRequest("one"))
        AttestStub.requests = []
        let second = await s.sign(aiRequest("two"))
        XCTAssertTrue(AttestStub.requests.isEmpty); XCTAssertEqual(service.keysMade, 1)
        XCTAssertEqual(second.value(forHTTPHeaderField: AppAttestSigner.assertionHeader), Data("assertion-2".utf8).base64EncodedString())
        XCTAssertEqual(service.assertedHashes.last, Data(SHA256.hash(data: Data("two".utf8))))
    }

    func testIfTheServerRefusesTheKeyTheRequestStillGoesOutAndNothingIsRemembered() async {
        AttestStub.handler = { request in request.httpMethod == "GET" ? (200, self.json(["challenge": "c"])) : (422, self.json(["error": "attestation_rejected"])) }
        let signed = await signer(FakeAttestService()).sign(aiRequest())
        XCTAssertNil(signed.value(forHTTPHeaderField: AppAttestSigner.assertionHeader))
        XCTAssertNil(defaults.string(forKey: "appAttestKeyID"))
    }

    func testIfTheServerIsUnreachableTheRequestStillGoesOut() async {
        AttestStub.handler = { _ in (503, Data()) }
        let signed = await signer(FakeAttestService()).sign(aiRequest())
        XCTAssertNil(signed.value(forHTTPHeaderField: AppAttestSigner.keyHeader))
    }

    func testAKeyThatCanNoLongerSignIsForgottenAndRegisteredAgain() async {
        serverAccepts()
        let service = FakeAttestService(), s = signer(service)
        _ = await s.sign(aiRequest())
        service.assertionFails = true
        let failed = await s.sign(aiRequest())
        XCTAssertNil(failed.value(forHTTPHeaderField: AppAttestSigner.assertionHeader)); XCTAssertNil(defaults.string(forKey: "appAttestKeyID"))
        service.assertionFails = false
        let recovered = await s.sign(aiRequest())
        XCTAssertEqual(service.keysMade, 2, "a new key was made")
        XCTAssertEqual(recovered.value(forHTTPHeaderField: AppAttestSigner.keyHeader), "key-2")
    }

    func testResettingForgetsTheKey() async {
        serverAccepts()
        let service = FakeAttestService(), s = signer(service)
        _ = await s.sign(aiRequest()); await s.reset()
        XCTAssertNil(defaults.string(forKey: "appAttestKeyID"))
        _ = await s.sign(aiRequest()); XCTAssertEqual(service.keysMade, 2)
    }

    // MARK: Every attempt is signed on its own

    func testARetryIsSignedAgainBecauseASignedRequestCannotBeSentTwice() async throws {
        var calls = 0
        AttestStub.handler = { _ in calls += 1; return calls == 1 ? (503, Data()) : (200, self.json(["content": []])) }
        let counting = CountingSigner()
        var request = URLRequest(url: URL(string: "https://example.test/api/ai")!); request.httpMethod = "POST"; request.httpBody = Data("x".utf8)
        _ = try await ClaudeAPI.send(request, session: session, retryDelay: .milliseconds(1), retryable: [503], signer: counting)
        XCTAssertEqual(AttestStub.requests.map { $0.value(forHTTPHeaderField: "x-test-signature") }, ["signature-1", "signature-2"])
    }

    func testOnlyAddingCreditsIsSignedNotTheStatusCheck() async throws {
        AttestStub.handler = { _ in (200, self.json(["paywall": true, "allowance": ["free": 5, "credits": 0]])) }
        let counting = CountingSigner()
        let client = AllowanceClient(endpoint: URL(string: "https://example.test/api/ai/account")!, installKey: { self.installKey }, entitlement: { nil }, signer: counting, session: session)
        _ = try await client.status(); XCTAssertEqual(counting.count, 0)
        AttestStub.handler = { _ in (200, self.json(["added": 25, "allowance": ["free": 0, "credits": 25]])) }
        _ = try await client.redeem("jws"); XCTAssertEqual(counting.count, 1)
    }

    func testWhenTheServerRejectsTheProofTheKeyIsForgottenSoTheNextTryRegistersAFreshOne() async throws {
        UserDefaults.standard.set("stale-key", forKey: "appAttestKeyID")
        let body = json(["error": "attest_invalid", "message": "This copy of SellPilot could not be verified. Close and reopen the app and try again."])
        XCTAssertNil(HostedAI.failure(status: 401, body: body), "the server's own message is the one shown")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(UserDefaults.standard.string(forKey: "appAttestKeyID"))
        XCTAssertEqual(HostedAI.errorMessage(status: 401, body: body), "This copy of SellPilot could not be verified. Close and reopen the app and try again.")
    }

    // MARK: The app and the server must use the same names. These fail if they drift apart.

    func testTheHeaderNamesAreTheOnesTheServerReads() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["netlify/functions/ai.mjs", "netlify/functions/ai-account.mjs"] {
            let source = try String(contentsOf: repo.appendingPathComponent("server/ebay-auth/\(file)"), encoding: .utf8)
            XCTAssertTrue(source.contains("\"\(AppAttestSigner.keyHeader)\""), "\(file) does not read \(AppAttestSigner.keyHeader)")
            XCTAssertTrue(source.contains("\"\(AppAttestSigner.assertionHeader)\""), "\(file) does not read \(AppAttestSigner.assertionHeader)")
        }
        let attest = try String(contentsOf: repo.appendingPathComponent("server/ebay-auth/lib/attest.mjs"), encoding: .utf8)
        XCTAssertTrue(attest.contains("2XC3GTJ8B8.com.tidewrightstudios.sellpilot"), "the server checks a different app id")
        XCTAssertEqual(HostedAI.attestEndpoint().lastPathComponent, "attest"); XCTAssertEqual(HostedAI.attestEndpoint().deletingLastPathComponent(), HostedAI.defaultEndpoint.deletingLastPathComponent())
    }

    func testTheAppDeclaresTheAppAttestCapability() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let entitlements = try String(contentsOf: repo.appendingPathComponent("SellPilot/SellPilot.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("com.apple.developer.devicecheck.appattest-environment"))
        let project = try String(contentsOf: repo.appendingPathComponent("generate_project.py"), encoding: .utf8)
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = SellPilot/SellPilot.entitlements"))
    }
}
