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

/// Catches the easy mistake of saving a Sandbox App ID in a Production field (or the reverse). eBay App IDs contain `-SBX-` or `-PRD-`.
enum EbayKeyCheck {
    static func problem(appID: String, production: Bool) -> String? {
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if id.isEmpty { return nil }
        if production && id.contains("-SBX-") { return "That looks like a Sandbox App ID. Production App IDs contain \"-PRD-\"." }
        if !production && id.contains("-PRD-") { return "That looks like a Production App ID. Sandbox App IDs contain \"-SBX-\"." }
        return nil
    }
}
