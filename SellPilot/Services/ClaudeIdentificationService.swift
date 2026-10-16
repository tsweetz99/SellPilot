import Foundation

/// Identifies an item from its photos with a Claude vision model, asking it to answer through a tool call so the reply is structured JSON.
/// Forced tool choice ("tool"/"any") is rejected by current models, so the tool is required by instruction and tool_choice is "auto".
struct ClaudeIdentificationService: ProductIdentificationService {
    struct Configuration {
        var apiKey: String
        var endpoint = ClaudeAPI.defaultEndpoint
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
    Give up to 3 alternates only when there is real doubt. \
    If the photos show more than one item, identify the most prominent one and mention the others in condition_notes. \
    You must answer by calling the report_identification tool; do not reply with plain text.
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
        let data = try await ClaudeAPI.send(request, session: session, retryDelay: configuration.retryDelay)
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
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": content]],
        ]
        return try ClaudeAPI.request(endpoint: configuration.endpoint, apiKey: configuration.apiKey, timeout: configuration.timeout, body: body)
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
        guard let inputData = ClaudeAPI.toolInput(named: Self.toolName, in: data), let payload = try? JSONDecoder().decode(Payload.self, from: inputData) else {
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
