import Foundation

/// Asks Claude to fill eBay's required item specifics from what is known about the item. Values for restricted
/// aspects must come from eBay's allowed list, and anything it cannot support from the facts is left blank for the seller.
struct ClaudeSpecificsFiller: ItemSpecificsService {
    struct Configuration {
        var apiKey: String
        var endpoint = ClaudeAPI.defaultEndpoint
        var model = "claude-haiku-4-5-20251001"
        var maxAllowedValues = 40
        var timeout: TimeInterval = 45
        var retryDelay: Duration = .seconds(2)
    }
    var configuration: Configuration
    var session: URLSession = .shared
    private static let toolName = "report_specifics"

    private static let systemPrompt = """
    You fill in eBay item specifics for a second-hand item using only the facts the seller gave. \
    For each aspect, return a value only if the facts clearly support it; otherwise return null. Never guess. \
    When an aspect lists allowed values you must return exactly one of them. \
    Infer yes/no aspects from the title, model number and notes (for example a model ending in B or the words "tool only" mean no battery included). \
    Answer by calling the report_specifics tool.
    """

    func makeRequest(item: SellItem, aspects: [EbayAspect]) throws -> URLRequest {
        func line(_ label: String, _ value: String) -> String? { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "\(label): \(value)" }
        let facts = [line("Title", item.title), line("Brand", item.brand), line("Model", item.model), line("Category", item.category), line("Color", item.color), line("Condition", item.condition.rawValue),
                     line("Condition notes", item.conditionNotes), line("Seller notes", item.sellerNotes),
                     line("Identification details", (item.identification?.recognizedAttributes ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))].compactMap { $0 }.joined(separator: "\n")
        let wanted = aspects.map { aspect -> String in
            aspect.selectionOnly && !aspect.values.isEmpty ? "- \(aspect.name) (allowed: \(aspect.values.prefix(configuration.maxAllowedValues).joined(separator: " | ")))" : "- \(aspect.name) (free text)"
        }.joined(separator: "\n")
        let schema: [String: Any] = ["type": "object", "properties": ["values": ["type": "array", "items": ["type": "object",
            "properties": ["name": ["type": "string"], "value": ["type": ["string", "null"]]], "required": ["name", "value"]]]], "required": ["values"]]
        let body: [String: Any] = [
            "model": configuration.model, "max_tokens": 1000, "system": Self.systemPrompt,
            "tools": [["name": Self.toolName, "description": "Report the item specific values.", "input_schema": schema]], "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": "Facts about the item:\n\(facts)\n\nAspects to fill:\n\(wanted)\n\nCall report_specifics with one entry per aspect."]],
        ]
        return try ClaudeAPI.request(endpoint: configuration.endpoint, apiKey: configuration.apiKey, timeout: configuration.timeout, body: body)
    }

    private struct Payload: Decodable { struct Entry: Decodable { var name: String; var value: String? }; var values: [Entry] }

    func fill(item: SellItem, aspects: [EbayAspect]) async throws -> [String: String] {
        guard !aspects.isEmpty else { return [:] }
        let data = try await ClaudeAPI.send(try makeRequest(item: item, aspects: aspects), session: session, retryDelay: configuration.retryDelay)
        guard let input = ClaudeAPI.toolInput(named: Self.toolName, in: data), let payload = try? JSONDecoder().decode(Payload.self, from: input) else {
            throw ServiceError.invalid("The item specifics result could not be read.")
        }
        var result: [String: String] = [:]
        for entry in payload.values {
            guard let aspect = aspects.first(where: { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }), let value = entry.value, let valid = aspect.normalized(value) else { continue }
            result[aspect.name] = valid
        }
        return result
    }
}
