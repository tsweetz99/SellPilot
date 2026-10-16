import Foundation

/// Decides which candidate listings are really the same product and configuration as the seller's item.
protocol ComparableFilterService {
    /// Indexes into `comparables` that match the item.
    func matchingIndexes(in comparables: [MarketComparable], for item: SellItem) async throws -> Set<Int>
}

/// Wraps a research service and keeps only listings the filter confirms are the same item, so prices are not
/// skewed by kits, accessories, other models or lots. If the filter fails or confirms too few listings, all
/// results are returned unverified, and the pricing summary says so.
struct FilteredMarketResearchService: MarketResearchService {
    var base: any MarketResearchService
    var filter: any ComparableFilterService
    var minimumMatches = AskingPricePricingService.minimumListings

    func research(item: SellItem) async throws -> [MarketComparable] {
        let comparables = try await base.research(item: item)
        guard let matches = try? await filter.matchingIndexes(in: comparables, for: item), matches.count >= minimumMatches else { return comparables }
        return comparables.enumerated().filter { matches.contains($0.offset) }.map { var comparable = $0.element; comparable.verifiedMatch = true; return comparable }
    }
}

struct ClaudeComparableFilter: ComparableFilterService {
    struct Configuration {
        var apiKey: String
        var endpoint = ClaudeAPI.defaultEndpoint
        /// Classifying titles is simple, so a small fast model is enough.
        var model = "claude-haiku-4-5-20251001"
        var maxListings = 50
        var timeout: TimeInterval = 45
        var retryDelay: Duration = .seconds(2)
    }
    var configuration: Configuration
    var session: URLSession = .shared

    private static let toolName = "report_matches"

    private static let systemPrompt = """
    You help a seller price a second-hand item by choosing which marketplace listings are truly comparable to it. \
    Keep a listing only if it is the same product (same brand and model) in the same configuration as the seller's item. \
    Configuration means what is included and which variant it is: for example bare tool versus kit with battery and charger, \
    capacity, size, color or generation where they differ materially. \
    Exclude: different models; accessories, parts, cases or batteries sold alone; lots, bundles and multiples; kits when the seller has the bare item (and the reverse); \
    items listed as broken or for parts when the seller's item works. \
    Infer the seller's configuration from the title, model number (for example a trailing B often means bare tool), condition notes and seller notes. \
    If the configuration is unclear, keep listings that match the model number exactly and exclude clearly different bundles. \
    Judge only from the titles. Answer by calling the report_matches tool.
    """

    private static var toolSchema: [String: Any] {
        ["type": "object",
         "properties": [
            "matching_indexes": ["type": "array", "items": ["type": "integer"], "description": "Numbers of the listings that match the seller's item."],
            "notes": ["type": "string", "description": "One short sentence on what you excluded and why."],
         ],
         "required": ["matching_indexes"]]
    }

    func makeRequest(comparables: [MarketComparable], item: SellItem) throws -> URLRequest {
        func line(_ label: String, _ value: String) -> String? { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "\(label): \(value)" }
        let description = [line("Title", item.title), line("Brand", item.brand), line("Model", item.model), line("Category", item.category),
                           line("Condition", item.condition.rawValue), line("Condition notes", item.conditionNotes), line("Seller notes", item.sellerNotes),
                           line("Identification details", (item.identification?.recognizedAttributes ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))]
            .compactMap { $0 }.joined(separator: "\n")
        let titles = comparables.prefix(configuration.maxListings).enumerated().map { "\($0.offset). \($0.element.title)" }.joined(separator: "\n")
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 1000,
            "system": Self.systemPrompt,
            "tools": [["name": Self.toolName, "description": "Report which listings match the seller's item.", "input_schema": Self.toolSchema]],
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": "Seller's item:\n\(description)\n\nCandidate listings:\n\(titles)\n\nCall report_matches with the numbers of the matching listings."]],
        ]
        return try ClaudeAPI.request(endpoint: configuration.endpoint, apiKey: configuration.apiKey, timeout: configuration.timeout, body: body)
    }

    private struct Payload: Decodable { var matching_indexes: [Int] }

    func matchingIndexes(in comparables: [MarketComparable], for item: SellItem) async throws -> Set<Int> {
        guard !comparables.isEmpty else { return [] }
        let data = try await ClaudeAPI.send(try makeRequest(comparables: comparables, item: item), session: session, retryDelay: configuration.retryDelay)
        guard let input = ClaudeAPI.toolInput(named: Self.toolName, in: data), let payload = try? JSONDecoder().decode(Payload.self, from: input) else {
            throw ServiceError.invalid("The listing filter result could not be read.")
        }
        let limit = min(comparables.count, configuration.maxListings)
        return Set(payload.matching_indexes.filter { (0..<limit).contains($0) })
    }
}
