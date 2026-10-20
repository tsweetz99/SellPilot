import Foundation

/// The studio-hosted AI service, so people do not need their own Anthropic key. The app sends only photos (or the seller's own
/// description); the service owns the instructions and answers with the same structure the direct Claude path produces.
/// Each install identifies itself with its random install code, which gives it its own daily allowance on the server.
enum HostedAI {
    static let defaultEndpoint = URL(string: "https://sellpilot-auth.netlify.app/api/ai")!

    /// Debug builds can point at another server with SELLPILOT_AI_ENDPOINT.
    static func endpoint() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["SELLPILOT_AI_ENDPOINT"], let url = URL(string: override) { return url }
        #endif
        return defaultEndpoint
    }

    static let disclosure = "To identify your item, the photos you analyze are sent to SellPilot's AI service, which uses Anthropic's Claude. They are not stored."
    static let providerName = "SellPilot AI"

    /// The service explains its own refusals in plain words ("you've reached today's limit"); show those as they are.
    static func errorMessage(status: Int, body: Data) -> String? {
        if let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
if status == 401 { return "This copy of SellPilot could not be verified. Update the app and try again." }
        // Anything else without an explanation (the service not reachable at its address, a gateway error): don't show a bare code.
        return status >= 400 ? "SellPilot's AI service isn't available right now. Try again later, or enter the details yourself." : nil
    }

    /// Only repeat what is safe: a limit or a timeout is not worth retrying, a brief outage is.
    static let retryable: Set<Int> = [502, 503]

    static func request(endpoint: URL, installKey: String, timeout: TimeInterval, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(installKey, forHTTPHeaderField: "x-sellpilot-install")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

/// Whether the seller has agreed to send photos and descriptions to an AI service. Asked once, before the first analysis.
enum AIConsent {
    private static let key = "aiConsentGiven"
    static var given: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct HostedIdentificationService: ProductIdentificationService {
    struct Configuration {
        var endpoint = HostedAI.endpoint()
        var installKey: () -> String = { APIKeyStore.installKey() }
        var maxPhotos = 6
        var maxImagePixels = 1280
        var timeout: TimeInterval = 75
        var retryDelay: Duration = .seconds(2)
    }
    var configuration = Configuration()
    var session: URLSession = .shared

    var disclosure: String? { HostedAI.disclosure }

    func makeRequest(photos: [SellItemPhoto]) throws -> URLRequest {
        let chosen = Array(photos.prefix(configuration.maxPhotos))
        var encoded: [[String: String]] = []
        for (index, photo) in chosen.enumerated() {
            guard let source = photo.previewData ?? Optional(photo.originalData).flatMap({ $0.isEmpty ? nil : $0 }),
                  let jpeg = ImageResizer.jpeg(from: source, maxPixel: configuration.maxImagePixels, quality: 0.75) else {
                throw ServiceError.invalid("Photo \(index + 1) could not be read. Remove it and add it again.")
            }
            encoded.append(["data": jpeg.base64EncodedString()])
        }
        return try HostedAI.request(endpoint: configuration.endpoint, installKey: configuration.installKey(), timeout: configuration.timeout, body: ["task": "identify", "photos": encoded])
    }

    func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification {
        guard !photos.isEmpty else { throw ServiceError.invalid("Add at least one photo.") }
        let data = try await ClaudeAPI.send(try makeRequest(photos: photos), session: session, retryDelay: configuration.retryDelay, retryable: HostedAI.retryable, errorMessage: HostedAI.errorMessage)
        return try ClaudeIdentificationService.parse(data, photoCount: min(photos.count, configuration.maxPhotos), provider: HostedAI.providerName)
    }
}

struct HostedItemFactsService: ItemSpecificsService {
    struct Configuration {
        var endpoint = HostedAI.endpoint()
        var installKey: () -> String = { APIKeyStore.installKey() }
        var timeout: TimeInterval = 45
        var retryDelay: Duration = .seconds(2)
    }
    var configuration = Configuration()
    var session: URLSession = .shared

    func makeRequest(item: SellItem) throws -> URLRequest {
        try HostedAI.request(endpoint: configuration.endpoint, installKey: configuration.installKey(), timeout: configuration.timeout,
                             body: ["task": "facts", "description": String(ClaudeItemFactsService.describe(item).prefix(4000))])
    }

    func facts(for item: SellItem) async throws -> [String: String] {
        let data = try await ClaudeAPI.send(try makeRequest(item: item), session: session, retryDelay: configuration.retryDelay, retryable: HostedAI.retryable, errorMessage: HostedAI.errorMessage)
        return try ClaudeItemFactsService.parseFacts(data)
    }
}
