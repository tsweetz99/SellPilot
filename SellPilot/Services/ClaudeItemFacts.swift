import Foundation

/// Asks Claude for generic facts about the item (voltage, color, size, whether a battery is included...) from the seller's own
/// description. Nothing from eBay is sent: eBay's API terms restrict feeding its content to AI tools, so the match between these
/// facts and eBay's required item specifics, and eBay's allowed values, is done on the device (see `EbaySpecifics.fill`).
struct ClaudeItemFactsService: ItemSpecificsService {
    struct Configuration {
        var apiKey: String
        var endpoint = ClaudeAPI.defaultEndpoint
        var model = "claude-haiku-4-5-20251001"
        var timeout: TimeInterval = 45
        var retryDelay: Duration = .seconds(2)
    }
    var configuration: Configuration
    var session: URLSession = .shared
    private static let toolName = "report_facts"
    static let factNames = ["brand", "model", "product_type", "color", "material", "size", "voltage", "power_source", "battery_included", "capacity", "quantity", "year", "country_of_origin", "style", "pattern", "features"]

    static let systemPrompt = """
    You extract facts about a second-hand item from the seller's own description. Return a fact only if the description clearly supports it; \
    leave everything else out. Never guess. For battery_included answer yes or no (a model ending in B or the words "tool only" mean no). \
    Use "other" for any further facts that are clearly stated. Answer by calling the report_facts tool.
    """

    /// The seller's own words about the item, as plain text. Shared with the hosted service, which receives only this.
    static func describe(_ item: SellItem) -> String {
        func line(_ label: String, _ value: String) -> String? { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "\(label): \(value)" }
        return [line("Title", item.title), line("Brand", item.brand), line("Model", item.model), line("Category", item.category), line("Color", item.color), line("Condition", item.condition.rawValue),
                           line("Condition notes", item.conditionNotes), line("Seller notes", item.sellerNotes),
                           line("Identification details", (item.identification?.recognizedAttributes ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))].compactMap { $0 }.joined(separator: "\n")
    }

    func makeRequest(item: SellItem) throws -> URLRequest {
        let description = Self.describe(item)
        var properties: [String: Any] = Dictionary(uniqueKeysWithValues: Self.factNames.map { ($0, ["type": "string"] as [String: Any]) })
        properties["other"] = ["type": "object", "additionalProperties": ["type": "string"], "description": "Other clearly stated facts, keyed by a short name."]
        let body: [String: Any] = [
            "model": configuration.model, "max_tokens": 800, "system": Self.systemPrompt,
            "tools": [["name": Self.toolName, "description": "Report facts about the item.", "input_schema": ["type": "object", "properties": properties]]], "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": "The seller's description of the item:\n\(description)\n\nCall report_facts with the facts the description supports."]],
        ]
        return try ClaudeAPI.request(endpoint: configuration.endpoint, apiKey: configuration.apiKey, timeout: configuration.timeout, body: body)
    }

    func facts(for item: SellItem) async throws -> [String: String] {
        let data = try await ClaudeAPI.send(try makeRequest(item: item), session: session, retryDelay: configuration.retryDelay)
        return try Self.parseFacts(data)
    }

    /// Turns the tool answer into lower-cased, underscore-named facts; "unknown" and empty values are dropped.
    static func parseFacts(_ data: Data) throws -> [String: String] {
        guard let input = ClaudeAPI.toolInput(named: Self.toolName, in: data), let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            throw ServiceError.invalid("The item facts result could not be read.")
        }
        var result: [String: String] = [:]
        func add(_ key: String, _ value: Any?) {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.lowercased() != "unknown" else { return }
            result[key.lowercased().replacingOccurrences(of: " ", with: "_")] = text
        }
        for (key, value) in object where key != "other" { add(key, value) }
        for (key, value) in (object["other"] as? [String: Any]) ?? [:] { add(key, value) }
        return result
    }
}
