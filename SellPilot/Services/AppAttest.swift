import Foundation
import CryptoKit
import DeviceCheck

/// Adds proof to a request that it comes from a genuine copy of SellPilot on a real Apple device.
protocol RequestSigner: Sendable {
    /// Returns the request with its proof attached, or unchanged if proof is not available (the server decides what to do then).
    func sign(_ request: URLRequest) async -> URLRequest
    /// Forgets the device key, so the next request registers a fresh one (used when the server says the proof was not accepted).
    func reset() async
}

/// The part of Apple's App Attest the signer needs, so it can be replaced in tests (the simulator has no App Attest).
protocol AttestKeyService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

struct DeviceAttestKeyService: AttestKeyService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }
    func generateKey() async throws -> String { try await DCAppAttestService.shared.generateKey() }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data { try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) }
}

/// App Attest for the hosted AI service. The first time, the app asks the server for a challenge, has Apple vouch for a new
/// hardware-backed key, and registers that key with the server. After that, every request carries a signature made with the
/// key over the request body, which the server checks. If anything goes wrong the request is sent without proof: whether
/// that is allowed is the server's decision, so a hiccup here never leaves a seller stuck by itself.
actor AppAttestSigner: RequestSigner {
    static let shared = AppAttestSigner()

    static let keyHeader = "x-sellpilot-attest-key"
    static let assertionHeader = "x-sellpilot-assertion"
    private static let keyDefaultsKey = "appAttestKeyID"

    private let service: AttestKeyService
    private let endpoint: URL
    private let installKey: @Sendable () -> String
    private let session: URLSession
    private let defaults: UserDefaults
    private let enabled: Bool

    init(service: AttestKeyService = DeviceAttestKeyService(), endpoint: URL = HostedAI.attestEndpoint(), installKey: @escaping @Sendable () -> String = { APIKeyStore.installKey() },
         session: URLSession = .shared, defaults: UserDefaults = .standard, enabled: Bool = !ProcessInfo.processInfo.arguments.contains("--ui-testing")) {
        self.service = service; self.endpoint = endpoint; self.installKey = installKey; self.session = session; self.defaults = defaults; self.enabled = enabled
    }

    func sign(_ request: URLRequest) async -> URLRequest {
        guard enabled, service.isSupported else { return request }
        do {
            let keyID = try await registeredKeyID()
            let hash = Data(SHA256.hash(data: request.httpBody ?? Data()))
            let assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
            var signed = request
            signed.setValue(keyID, forHTTPHeaderField: Self.keyHeader)
            signed.setValue(assertion.base64EncodedString(), forHTTPHeaderField: Self.assertionHeader)
            return signed
        } catch {
            // A key that cannot sign is of no use again (it was lost, or the app was restored): start over next time.
            defaults.removeObject(forKey: Self.keyDefaultsKey)
            return request
        }
    }

    func reset() { defaults.removeObject(forKey: Self.keyDefaultsKey) }

    /// The id of this install's registered key, registering a new one first if there is none.
    private func registeredKeyID() async throws -> String {
        if let existing = defaults.string(forKey: Self.keyDefaultsKey) { return existing }
        let challenge = try await fetchChallenge()
        let keyID = try await service.generateKey()
        let attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        try await register(keyID: keyID, attestation: attestation, challenge: challenge)
        defaults.set(keyID, forKey: Self.keyDefaultsKey)
        return keyID
    }

    private func fetchChallenge() async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue(installKey(), forHTTPHeaderField: "x-sellpilot-install")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let challenge = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["challenge"] as? String else { throw URLError(.badServerResponse) }
        return challenge
    }

    private func register(keyID: String, attestation: Data, challenge: String) async throws {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(installKey(), forHTTPHeaderField: "x-sellpilot-install")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keyId": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge])
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
    }
}
