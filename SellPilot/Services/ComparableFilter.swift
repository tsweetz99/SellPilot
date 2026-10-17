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

/// Matches listing titles to the seller's item with plain rules. eBay's listing data never leaves the device for this:
/// eBay's API terms restrict feeding its content to AI tools, so this step deliberately uses no AI.
struct TitleComparableFilter: ComparableFilterService {
    private static let stopWords: Set<String> = ["the", "and", "with", "for", "new", "used", "set", "of", "in", "a", "an", "by", "to", "free", "shipping"]

    func matchingIndexes(in comparables: [MarketComparable], for item: SellItem) async throws -> Set<Int> {
        let seller = ItemConfiguration(text: ItemConfiguration.sellerText(for: item))
        let keys = Self.modelKeys(item.model)
        let words = Self.significantWords(item)
        var matches = Set<Int>()
        for (index, comparable) in comparables.enumerated() {
            guard keys.isEmpty ? Self.coversWords(comparable.title, words: words) : Self.titleHasModel(comparable.title, keys: keys) else { continue }
            let listing = ItemConfiguration(text: comparable.title)
            if listing.accessoryOnly && !seller.accessoryOnly { continue }
            if listing.forParts && !(seller.forParts || item.condition == .parts) { continue }
            if listing.lot && !seller.lot { continue }
            if seller.bare && listing.kit && !listing.bare { continue }
            if seller.kit && listing.bare && !listing.kit { continue }
            matches.insert(index)
        }
        return matches
    }

    /// The model as typed, and without a trailing letter (DCF887B also covers DCF887).
    static func modelKeys(_ model: String) -> [String] {
        let compact = TitleText.compact(model)
        guard compact.count >= 3, compact != "unknown" else { return [] }
        var keys = [compact]
        if compact.count >= 5, let last = compact.last, last.isLetter, compact.dropLast().contains(where: \.isNumber) { keys.append(String(compact.dropLast())) }
        return keys
    }

    static func titleHasModel(_ title: String, keys: [String]) -> Bool {
        let tokens = TitleText.tokens(title), compact = tokens.joined()
        return keys.contains { key in
            tokens.contains { $0 == key || ($0.hasPrefix(key) && $0.count - key.count <= 2) } || (key.count >= 6 && compact.contains(key))
        }
    }

    static func significantWords(_ item: SellItem) -> [String] {
        let brand = item.brand.lowercased() == "unknown" ? "" : item.brand
        var seen = Set<String>()
        return TitleText.tokens("\(item.title) \(brand)").filter { $0.count >= 3 && !stopWords.contains($0) && seen.insert($0).inserted }
    }

    /// Without a model number, a listing must contain at least three quarters of the item's own distinguishing words.
    static func coversWords(_ title: String, words: [String]) -> Bool {
        guard words.count >= 2 else { return true }
        let present = Set(TitleText.tokens(title))
        return words.filter { present.contains($0) }.count >= Int((Double(words.count) * 0.75).rounded(.up))
    }
}
