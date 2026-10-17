import Foundation

enum TitleText {
    /// Lowercase, with everything that is not a letter or digit turned into a single space.
    static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
    static func tokens(_ text: String) -> [String] { normalize(text).split(separator: " ").map(String.init) }
    static func compact(_ text: String) -> String { normalize(text).replacingOccurrences(of: " ", with: "") }
    static func contains(_ normalized: String, phrase: String) -> Bool { " \(normalized) ".contains(" \(phrase) ") }
}

/// What a piece of text (the seller's own description, or a listing title) says about how the item is sold:
/// bare or in a kit, for parts, accessory only, or a lot. Plain wording rules, no AI.
struct ItemConfiguration: Equatable {
    var bare = false, kit = false, forParts = false, accessoryOnly = false, lot = false

    private static let barePhrases = ["tool only", "bare tool", "body only", "no battery", "without battery", "battery not included", "batteries not included", "bare unit", "unit only", "skin only", "naked tool"]
    private static let kitPhrases = ["kit", "with battery", "w battery", "with batteries", "battery and charger", "batteries and charger", "includes battery", "with charger", "w charger", "combo"]
    private static let partsPhrases = ["for parts", "parts only", "parts or repair", "not working", "broken", "faulty", "does not work", "doesnt work", "for repair"]
    private static let accessoryPhrases = ["charger only", "battery only", "batteries only", "case only", "manual only", "box only", "bag only", "replacement", "accessory", "accessories", "adapter only", "cover only"]
    private static let lotPhrases = ["lot of", "job lot", "lot", "bundle", "wholesale", "set of"]

    init(text: String) {
        let normalized = TitleText.normalize(text)
        func has(_ phrases: [String]) -> Bool { phrases.contains { TitleText.contains(normalized, phrase: $0) } }
        bare = has(Self.barePhrases); kit = has(Self.kitPhrases); forParts = has(Self.partsPhrases); accessoryOnly = has(Self.accessoryPhrases)
        lot = has(Self.lotPhrases) || normalized.range(of: #"\b\d+ (pack|pcs|pieces|piece|units|pk)\b"#, options: .regularExpression) != nil
    }

    /// Everything the seller has told us about the item, as one string.
    static func sellerText(for item: SellItem) -> String {
        [item.title, item.brand, item.model, item.conditionNotes, item.sellerNotes, (item.identification?.recognizedAttributes ?? [:]).values.joined(separator: " ")].joined(separator: " ")
    }
}
