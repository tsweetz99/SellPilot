import Foundation

/// Whether SellPilot publishes to real eBay instead of the sandbox. Off by default; both values are kept on the device.
enum LiveSettings {
    private static let enabledKey = "livePublishingEnabled"
    private static let zipKey = "shipFromZip"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    /// Where the seller ships from, needed for eBay's inventory location.
    static var shipFromZip: String {
        get { UserDefaults.standard.string(forKey: zipKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: zipKey) }
    }
    static func isValidZip(_ zip: String) -> Bool { zip.range(of: "^[0-9]{5}$", options: .regularExpression) != nil }
}
