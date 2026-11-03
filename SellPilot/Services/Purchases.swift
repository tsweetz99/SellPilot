import Foundation
import StoreKit
import Observation

/// What SellPilot sells. The ids match App Store Connect and `server/ebay-auth/lib/products.mjs` (a test keeps them in step).
enum PlusProduct {
    static let monthly = "com.tidewrightstudios.sellpilot.plus.monthly"
    static let yearly = "com.tidewrightstudios.sellpilot.plus.yearly"
    static let pack = "com.tidewrightstudios.sellpilot.analyses.25"
    static let all = [monthly, yearly, pack]
    static let subscriptions: Set<String> = [monthly, yearly]
    static let freeAnalyses = 5
    static let plusPerPeriod = 60
    static let packSize = 25
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

/// One thing on the plans screen: its price and, when StoreKit supplied it, the product to buy.
struct PlanOffer: Identifiable {
    let id: String
    let displayPrice: String
    let price: Decimal
    var product: Product?
}

/// What the AI service says this install has left. The server is the one that counts; the app only shows it.
struct AIAllowance: Equatable, Codable {
    struct Plus: Equatable, Codable { var remaining: Int; var limit: Int; var renews: Double }
    var free: Int
    var credits: Int
    var plus: Plus?

    /// Analyses that can be run right now.
    var available: Int { free + credits + (plus?.remaining ?? 0) }

    /// One line for the capture screen and Settings.
    var summary: String {
        var parts: [String] = []
        if let plus { parts.append("\(plus.remaining) of \(plus.limit) Plus analyses left this period") }
        if free > 0 { parts.append("\(free) free analys\(free == 1 ? "is" : "es") left") }
        if credits > 0 { parts.append("\(credits) pack analys\(credits == 1 ? "is" : "es") left") }
        return parts.isEmpty ? "No analyses left" : parts.joined(separator: " · ")
    }

    static func parse(_ data: Data) -> AIAllowance? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = root["allowance"],
              let json = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(AIAllowance.self, from: json)
    }
}

/// The hosted service refused an analysis because the seller has none left. It is not a failure: the app shows the plans.
struct HostedAIError: LocalizedError, Equatable {
    var message: String
    /// What the server says is left (nothing), so the app's count is corrected and the plans do not reappear in a loop.
    var allowance: AIAllowance? = nil
    var errorDescription: String? { message }
}

/// Apple's signed record of the seller's current SellPilot Plus subscription, sent with every AI request so the server can
/// check it. Kept here, readable from any thread, because requests are built off the main actor.
enum EntitlementCache {
    private static let lock = NSLock()
    private static var value: String?
    static var jws: String? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

/// The two paywall requests to the AI service: what is left, and "add the pack I bought".
struct AllowanceClient {
    var endpoint = HostedAI.accountEndpoint()
    var installKey: () -> String = { APIKeyStore.installKey() }
    var entitlement: () -> String? = { EntitlementCache.jws }
    var signer: RequestSigner? = AppAttestSigner.shared
    var session: URLSession = .shared

    func makeRequest(redeeming transaction: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.setValue(installKey(), forHTTPHeaderField: "x-sellpilot-install")
        if let entitlement = entitlement() { request.setValue(entitlement, forHTTPHeaderField: "x-sellpilot-entitlement") }
        if let transaction {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["transaction": transaction])
        } else { request.httpMethod = "GET" }
        return request
    }

    struct Status: Equatable { var paywall: Bool; var allowance: AIAllowance }

    func status() async throws -> Status {
        let data = try await send(try makeRequest())
        guard let allowance = AIAllowance.parse(data) else { throw ServiceError.invalid("SellPilot's service sent an answer the app could not read.") }
        let paywall = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["paywall"] as? Bool ?? true
        return Status(paywall: paywall, allowance: allowance)
    }

    /// Resolves the new allowance once the server has added the pack (or already had it).
    func redeem(_ transaction: String) async throws -> AIAllowance {
        let data = try await send(try makeRequest(redeeming: transaction))
        guard let allowance = AIAllowance.parse(data) else { throw ServiceError.invalid("SellPilot's service sent an answer the app could not read.") }
        return allowance
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        let outgoing = request.httpMethod == "POST" ? (await signer?.sign(request) ?? request) : request   // adding credits is the request that needs proof
        do { (data, response) = try await session.data(for: outgoing) }
        catch { throw ServiceError.invalid("Couldn't reach SellPilot's service. Check your connection; your purchase is safe and will be added when it is back.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ServiceError.invalid(HostedAI.errorMessage(status: status, body: data) ?? "SellPilot's service isn't available right now.")
        }
        return data
    }
}

/// Plans, packs and what is left. StoreKit handles the buying; the AI service does the counting (so a copied app or a
/// reinstall cannot hand out free analyses) and learns about purchases only from transactions Apple has signed.
@MainActor @Observable final class PurchaseStore {
    static let shared = PurchaseStore()
    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--paywall-demo") {
            demoOffers = [PlanOffer(id: PlusProduct.monthly, displayPrice: "$4.99", price: 4.99), PlanOffer(id: PlusProduct.yearly, displayPrice: "$34.99", price: 34.99), PlanOffer(id: PlusProduct.pack, displayPrice: "$2.99", price: 2.99)]
            allowance = AIAllowance(free: 0, credits: 0, plus: nil)
        }
        #endif
    }

    private(set) var products: [Product] = []
    /// Debug builds can show the plans screen with made-up prices, to check its layout without the App Store.
    var demoOffers: [PlanOffer]?
    var offers: [PlanOffer] { demoOffers ?? products.map { PlanOffer(id: $0.id, displayPrice: $0.displayPrice, price: $0.price, product: $0) } }
    private(set) var allowance: AIAllowance?
    private(set) var hasPlus = false
    /// False when the studio has switched the paywall off on the server: then nothing here is shown.
    private(set) var paywallOn = true
    private(set) var busy = false
    var message: String?

    var client = AllowanceClient()
    private var listener: Task<Void, Never>?
    private var started = false

    /// UI tests and screenshots never touch the App Store or the network.
    private var disabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-testing") }

    var monthly: PlanOffer? { offers.first { $0.id == PlusProduct.monthly } }
    var yearly: PlanOffer? { offers.first { $0.id == PlusProduct.yearly } }
    var pack: PlanOffer? { offers.first { $0.id == PlusProduct.pack } }

    /// Call once at launch: loads prices, listens for purchases made elsewhere (renewals, Ask to Buy, another device), and finishes any pack that was bought but not yet added.
    func start() async {
        guard !started, !disabled else { return }
        started = true
        listener = Task { [weak self] in for await update in Transaction.updates { await self?.handle(update) } }
        await loadProducts()
        await refreshEntitlements()
        for await unfinished in Transaction.unfinished { await handle(unfinished) }
        await refreshAllowance()
    }

    func loadProducts() async {
        guard products.isEmpty, demoOffers == nil else { return }
        do {
            let loaded = try await Product.products(for: PlusProduct.all)
            products = PlusProduct.all.compactMap { id in loaded.first { $0.id == id } }
            if products.isEmpty { message = "Plans aren't available right now. Try again later." }
        } catch { message = "Couldn't load the plans: \(error.localizedDescription)" }
    }

    func refreshAllowance() async {
        guard !disabled else { return }
        do {
            let status = try await client.status()
            allowance = status.allowance; paywallOn = status.paywall
        } catch { /* The last known allowance stays on screen; the next analysis asks the server anyway. */ }
    }

    /// Remembers the allowance an analysis reported, so the capture screen stays right without another request.
    func record(_ allowance: AIAllowance) { self.allowance = allowance }

    func purchase(_ product: Product) async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification): await handle(verification)
            case .pending: message = "Waiting for approval. SellPilot will update when it comes through."
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = "The purchase didn't go through: \(error.localizedDescription)" }
        await refreshAllowance()
    }

    func restore() async {
        guard !busy else { return }
        busy = true; message = nil; defer { busy = false }
        do { try await AppStore.sync() } catch { message = "Couldn't restore purchases: \(error.localizedDescription)"; return }
        await refreshEntitlements()
        await refreshAllowance()
        message = hasPlus ? "SellPilot Plus is active on this account." : "No active subscription found. Packs you bought stay on the iPhone you bought them on."
    }

    /// Looks at what Apple says this account owns and keeps the subscription's signed record for the server.
    func refreshEntitlements() async {
        var best: (expires: Date, jws: String)?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, PlusProduct.subscriptions.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            let expires = transaction.expirationDate ?? .distantPast
            if best == nil || expires > best!.expires { best = (expires, result.jwsRepresentation) }
        }
        EntitlementCache.jws = best?.jws
        hasPlus = best != nil
    }

    /// One transaction from StoreKit. Subscriptions are noted and finished. A pack is finished only after the server has added
    /// it, so if the phone is offline the purchase is kept and added on a later launch instead of being lost.
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if PlusProduct.subscriptions.contains(transaction.productID) {
            await refreshEntitlements()
            await transaction.finish()
        } else if transaction.productID == PlusProduct.pack {
            do {
                allowance = try await client.redeem(result.jwsRepresentation)
                await transaction.finish()
                message = "Added \(PlusProduct.packSize) analyses."
            } catch { message = error.localizedDescription }
        } else { await transaction.finish() }
    }
}
