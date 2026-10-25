import XCTest
@testable import SellPilot

private final class DeploymentStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EbayDeploymentTests: XCTestCase {
    private var defaults: UserDefaults!
    private let server = URL(string: "https://example.test/api/ebay-token")!
    private let good = ["production": ["appID": "Studio-SellPilo-PRD-abc123-def456", "ruName": "Studio-SellPilo-StudioS-xyz"]]
    override func setUp() {
        defaults = UserDefaults(suiteName: "ebay-deployment-\(UUID().uuidString)")
        DeploymentStub.requests = []; DeploymentStub.handler = nil
    }
    private var session: URLSession { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeploymentStub.self]; return URLSession(configuration: config) }
    private func reply(_ object: Any, status: Int = 200) -> (Int, Data) { (status, try! JSONSerialization.data(withJSONObject: object)) }
    private let nothingSaved: (APIKeyStore.Account) -> String? = { _ in nil }

    func testTheConfigAddressSitsNextToTheTokenServer() {
        XCTAssertEqual(EbayDeployment.configURL(for: server).absoluteString, "https://example.test/api/ebay-config")
        XCTAssertEqual(EbayDeployment.configURL(for: EbayDeployment.defaultTokenServer).absoluteString, "https://sellpilot-auth.netlify.app/api/ebay-config")
    }

    func testFetchedSetupIsRememberedAndUsed() async {
        DeploymentStub.handler = { _ in self.reply(self.good) }
        XCTAssertNil(EbayDeployment.productionIdentity(defaults: defaults, load: nothingSaved), "nothing before the first fetch")
        let ok = await EbayDeployment.refresh(session: session, server: server, defaults: defaults)
        XCTAssertTrue(ok)
        XCTAssertEqual(DeploymentStub.requests.first?.url?.absoluteString, "https://example.test/api/ebay-config")
        XCTAssertEqual(EbayDeployment.productionIdentity(defaults: defaults, load: nothingSaved), .init(appID: "Studio-SellPilo-PRD-abc123-def456", ruName: "Studio-SellPilo-StudioS-xyz"))
    }

    func testBadAnswersNeverReplaceTheLastGoodSetup() async {
        DeploymentStub.handler = { _ in self.reply(self.good) }
        _ = await EbayDeployment.refresh(session: session, server: server, defaults: defaults)
        let bad: [(Int, Data)] = [
            reply(["error": "not_configured"], status: 503), reply(["production": ["appID": "Studio-SellPilo-SBX-aaa-bbb", "ruName": "ru"]]),
            reply(["production": ["appID": "Studio-PRD-1", "ruName": "  "]]), reply(["production": ["appID": 5]]), reply(["nope": 1]), (200, Data("<html>".utf8))]
        for answer in bad {
            DeploymentStub.handler = { _ in answer }
            let ok = await EbayDeployment.refresh(session: session, server: server, defaults: defaults)
            XCTAssertFalse(ok)
            XCTAssertEqual(EbayDeployment.productionIdentity(defaults: defaults, load: nothingSaved)?.appID, "Studio-SellPilo-PRD-abc123-def456")
        }
    }

    func testASandboxIdCanNeverBecomeTheProductionSetup() async {
        DeploymentStub.handler = { _ in self.reply(["production": ["appID": "Studio-SellPilo-SBX-aaa-bbb", "ruName": "ru"]]) }
        let ok = await EbayDeployment.refresh(session: session, server: server, defaults: defaults)
        XCTAssertFalse(ok); XCTAssertNil(EbayDeployment.productionIdentity(defaults: defaults, load: nothingSaved))
    }

    func testAnUnreachableServerChangesNothing() async {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = []
        let offline = URLSession(configuration: config)
        let ok = await EbayDeployment.refresh(session: offline, server: URL(string: "https://127.0.0.1:1/api/ebay-token")!, defaults: defaults)
        XCTAssertFalse(ok); XCTAssertNil(EbayDeployment.cached(defaults))
    }

    func testValuesADeveloperSavedOnThisDeviceWin() async {
        DeploymentStub.handler = { _ in self.reply(self.good) }
        _ = await EbayDeployment.refresh(session: session, server: server, defaults: defaults)
        let saved: (APIKeyStore.Account) -> String? = { $0 == .ebayAppID ? "Dev-App-PRD-1" : ($0 == .ebayRuName ? "Dev-RuName" : nil) }
        XCTAssertEqual(EbayDeployment.productionIdentity(defaults: defaults, load: saved), .init(appID: "Dev-App-PRD-1", ruName: "Dev-RuName"))
        let onlyOne: (APIKeyStore.Account) -> String? = { $0 == .ebayAppID ? "Dev-App-PRD-1" : nil }
        XCTAssertEqual(EbayDeployment.productionIdentity(defaults: defaults, load: onlyOne)?.appID, "Studio-SellPilo-PRD-abc123-def456", "half a saved pair is ignored")
    }

    // MARK: What the public app shows

    @MainActor func testThePublicAppSaysPublishingIsOffUntilTheSellerTurnsItOn() {
        let prior = LiveSettings.enabled; defer { LiveSettings.enabled = prior }
        LiveSettings.enabled = false
        let services = AppServices.make(mode: .public)
        XCTAssertEqual(services.ebaySetup, .turnedOff); XCTAssertTrue(services.ebayIsLive, "it only ever talks about real eBay")
        XCTAssertNil(services.ebay)
    }

    @MainActor func testTheDeveloperAppKeepsItsSandboxAndNeverShowsTheOffState() {
        let prior = LiveSettings.enabled; defer { LiveSettings.enabled = prior }
        LiveSettings.enabled = false
        let services = AppServices.make(mode: .developer)
        XCTAssertNotEqual(services.ebaySetup, .turnedOff); XCTAssertFalse(services.ebayIsLive)
    }

    @MainActor func testPublishingOnNeedsSignInOrSetupNeverTheOffState() {
        let prior = LiveSettings.enabled; defer { LiveSettings.enabled = prior }
        LiveSettings.enabled = true
        let services = AppServices.make(mode: .public)
        XCTAssertNotEqual(services.ebaySetup, .turnedOff)
        XCTAssertTrue(services.ebayIsLive)
    }

    func testTheSetupStatesAreDistinct() {
        var services = AppServices()
        XCTAssertEqual(services.ebaySetup, .notConfigured)
        services.ebayTurnedOff = true; XCTAssertEqual(services.ebaySetup, .turnedOff)
        services.ebayNeedsSignIn = true; XCTAssertEqual(services.ebaySetup, .needsSignIn, "sign-in outranks off")
    }
}
