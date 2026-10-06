import Foundation

/// Identifies an item from its photos with a Claude vision model, using a forced tool call so the reply is structured JSON.
struct ClaudeIdentificationService: ProductIdentificationService {
    struct Configuration {
        var apiKey: String
        var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var model = "claude-sonnet-5-5"
        var maxPhotos = 6
        var maxImagePixels = 1280
        var timeout: TimeInterval = 60
        var retryDelay: Duration = .seconds(2)
    }

    var configuration: Configuration
    var session: URLSession = .shared

    var disclosure: String? { "To identify your item, the photos you analyze are sent to Anthropic's Claude service." }

    private static let toolName = "report_identification"

    private static let systemPrompt = """
    You identify second-hand items for a seller's marketplace listing, using only the seller's photos. \
    Report only what the photos support. Read labels, rating plates and model stickers when legible and list the text you actually read in visible_text. \
    Never invent a model number: if none is legible and you are not certain, leave model_number null. \
    Use the brand "Unknown" when no brand is visible or recognizable. \
    confidence is your honest probability (0 to 1) that the title, brand and model are correct for this exact item; stay below 0.6 when guessing from shape alone. \
    Describe visible wear, damage and missing parts in condition_notes; never hide defects. \
    Give up to 3 alternates only when there is real doubt.
    """

    private static var toolSchema: [String: Any] {
        let match: [String: Any] = [
            "type": "object",
            "properties": ["title": ["type": "string"], "brand": ["type": "string"], "model": ["type": "string"], "category": ["type": "string", "enum": SellItem.categories]],
            "required": ["title", "brand", "model", "category"],
        ]
        return [
            "type": "object",
            "properties": [
                "title": ["type": "string", "description": "Marketplace-ready product name, e.g. brand + product + key spec."],
                "brand": ["type": "string"],
                "model": ["type": "string", "description": "Model name or number; empty string if unknown."],
                "model_number": ["type": ["string", "null"], "description": "Only a model/part number you can read or are certain of."],
                "category": ["type": "string", "enum": SellItem.categories],
                "subcategory": ["type": "string"],
                "color": ["type": "string"],
                "condition": ["type": "string", "enum": ItemCondition.allCases.map(\.rawValue)],
                "condition_notes": ["type": "string"],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "visible_text": ["type": "array", "items": ["type": "string"], "description": "Text read from labels, plates and packaging."],
                "attributes": ["type": "object", "additionalProperties": ["type": "string"], "description": "Other useful facts, e.g. voltage, size, material."],
                "alternates": ["type": "array", "items": match, "maxItems": 3],
            ],
            "required": ["title", "brand", "model", "category", "subcategory", "color", "condition", "confidence"],
        ]
    }

    func identify(photos: [SellItemPhoto]) async throws -> ProductIdentification {
        guard !photos.isEmpty else { throw ServiceError.invalid("Add at least one photo.") }
        let request = try makeRequest(photos: photos)
        let data = try await send(request)
        return try parse(data, photoCount: min(photos.count, configuration.maxPhotos))
    }

    // MARK: Request

    func makeRequest(photos: [SellItemPhoto]) throws -> URLRequest {
        let chosen = Array(photos.prefix(configuration.maxPhotos))
        var content: [[String: Any]] = []
        for (index, photo) in chosen.enumerated() {
            guard let source = photo.previewData ?? Optional(photo.originalData).flatMap({ $0.isEmpty ? nil : $0 }),
                  let jpeg = ImageResizer.jpeg(from: source, maxPixel: configuration.maxImagePixels, quality: 0.75) else {
                throw ServiceError.invalid("Photo \(index + 1) could not be read. Remove it and add it again.")
            }
            content.append(["type": "text", "text": "Photo \(index + 1) of \(chosen.count)\(index == 0 ? " (cover photo)" : "")"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": "Identify the item these photos show and call \(Self.toolName)."])
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 1500,
            "system": Self.systemPrompt,
            "tools": [["name": Self.toolName, "description": "Report the identification of the item in the photos.", "input_schema": Self.toolSchema]],
            "tool_choice": ["type": "tool", "name": Self.toolName],
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: Transport

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504, 529]

    private func send(_ request: URLRequest) async throws -> Data {
        for attempt in 0...1 {
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError {
                if attempt == 0, [.timedOut, .networkConnectionLost].contains(error.code) { try await Task.sleep(for: configuration.retryDelay); continue }
                throw ServiceError.invalid(Self.message(for: error))
            }
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalid("Unexpected response from the identification service.") }
            if (200..<300).contains(http.statusCode) { return data }
            if attempt == 0, Self.retryableStatuses.contains(http.statusCode) { try await Task.sleep(for: configuration.retryDelay); continue }
            throw ServiceError.invalid(Self.message(status: http.statusCode, body: data))
        }
        throw ServiceError.invalid("The identification service is unavailable. Try again shortly.")
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "No internet connection. Check your connection and try again."
        case .timedOut: "Identification took too long. Try again, or use fewer photos."
        default: "Could not reach the identification service: \(error.localizedDescription)"
        }
    }

    private static func message(status: Int, body: Data) -> String {
        let detail = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        switch status {
        case 401, 403: return "The identification API key was rejected. Check it in Settings."
        case 413: return "The photos are too large to analyze. Remove a few and try again."
        case 429: return "Identification is busy right now. Try again in a moment."
        case 500...599: return "The identification service is temporarily unavailable. Try again shortly."
        default: return "Identification failed (\(status))" + (detail.map { ": \($0)" } ?? ".")
        }
    }

    // MARK: Response

    private struct Payload: Decodable {
        struct Alternate: Decodable { var title: String; var brand: String?; var model: String?; var category: String? }
        var title: String; var brand: String; var model: String?; var modelNumber: String?
        var category: String; var subcategory: String?; var color: String?
        var condition: String?; var conditionNotes: String?; var confidence: Double
        var visibleText: [String]?; var attributes: [String: String]?; var alternates: [Alternate]?
        enum CodingKeys: String, CodingKey {
            case title, brand, model, category, subcategory, color, condition, confidence, attributes, alternates
            case modelNumber = "model_number", conditionNotes = "condition_notes", visibleText = "visible_text"
        }
    }

    func parse(_ data: Data, photoCount: Int) throws -> ProductIdentification {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["content"] as? [[String: Any]],
              let tool = blocks.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == Self.toolName }),
              let input = tool["input"],
              let inputData = try? JSONSerialization.data(withJSONObject: input),
              let payload = try? JSONDecoder().decode(Payload.self, from: inputData) else {
            throw ServiceError.invalid("The identification result could not be read. Try again.")
        }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ServiceError.invalid("This item could not be identified. Try clearer photos that include any label or model sticker.") }
        let model = (payload.model ?? payload.modelNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category = SellItem.categories.contains(payload.category) ? payload.category : "Other"
        var attributes = payload.attributes ?? [:]
        if let text = payload.visibleText?.filter({ !$0.isEmpty }), !text.isEmpty { attributes["Text seen in photos"] = text.joined(separator: " · ") }
        if let notes = payload.conditionNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty { attributes["Condition notes"] = notes }
        let alternates = (payload.alternates ?? []).prefix(3).map {
            ProductMatch(title: $0.title, brand: $0.brand ?? "Unknown", model: $0.model ?? "", category: SellItem.categories.contains($0.category ?? "") ? $0.category! : category)
        }
        // A single photo rarely shows enough to be sure; never report more than the evidence supports.
        let confidence = min(max(payload.confidence, 0), photoCount == 1 ? 0.8 : 1)
        return ProductIdentification(
            product: ProductMatch(title: title, brand: payload.brand, model: model, category: category),
            subcategory: payload.subcategory ?? "", color: payload.color ?? "",
            detectedCondition: payload.condition.flatMap(ItemCondition.init(rawValue:)) ?? .good,
            possibleModelNumber: payload.modelNumber.flatMap { $0.isEmpty ? nil : $0 },
            confidenceScore: confidence, alternateMatches: Array(alternates), recognizedAttributes: attributes,
            provider: configuration.model)
    }
}
