import SwiftUI
import StoreKit

/// The plans. Shown when a seller is out of analyses, and from Settings. Everything except photo analysis stays free.
struct PaywallView: View {
    /// Why it is showing ("You've used your free analyses…"), or nil when opened from Settings.
    var reason: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var store = PurchaseStore.shared

    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text("SellPilot Plus").font(.largeTitle.bold())
                Text(reason ?? "Analyzing photos uses an AI service that costs money to run, so your first \(PlusProduct.freeAnalyses) analyses are free and then you choose how to keep going.").foregroundStyle(PilotTheme.muted)
                if let allowance = store.allowance, store.paywallOn { Label(allowance.summary, systemImage: "sparkles").font(.subheadline.bold()).foregroundStyle(PilotTheme.accent) }
                if store.offers.isEmpty {
                    PilotCard { if let message = store.message { Text(message) } else { HStack { ProgressView(); Text("Loading plans…") } } }
                } else {
                    if let monthly = store.monthly { planCard(monthly, title: "Monthly", detail: "\(PlusProduct.plusPerPeriod) analyses every month", suffix: "per month", note: nil, id: "buyMonthly") }
                    if let yearly = store.yearly { planCard(yearly, title: "Yearly", detail: "\(PlusProduct.plusPerPeriod) analyses every month", suffix: "per year", note: savings, id: "buyYearly") }
                    if let pack = store.pack { planCard(pack, title: "\(PlusProduct.packSize) analyses", detail: "One payment, no subscription. They never expire.", suffix: nil, note: nil, id: "buyPack") }
                }
                if let message = store.message, !store.offers.isEmpty { Text(message).font(.footnote).foregroundStyle(PilotTheme.muted) }
                Text("Plus renews automatically each period until you cancel it in Settings, Apple ID, Subscriptions, at least a day before it renews. Payment is charged to your Apple account. Manual entry, price research and exporting listings are always free.").font(.footnote).foregroundStyle(PilotTheme.muted)
                AdaptiveStack(spacing: 16) {
                    Link("Terms of Use", destination: PlusProduct.termsURL)
                    Link("Privacy Policy", destination: PrivacyPolicy.url)
                    Button("Restore purchases") { Task { await store.restore() } }.disabled(store.busy)
                }.font(.footnote)
                Button("Not now") { dismiss() }.frame(maxWidth: .infinity).padding(.top, 4)
            }.padding(22) }
            .background(PilotTheme.background)
            .navigationTitle("Plans").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .task { await store.loadProducts(); await store.refreshAllowance() }
            // Once the seller has something to spend, the sheet gets out of the way.
            .onChange(of: store.allowance) { _, new in if reason != nil, (new?.available ?? 0) > 0 { dismiss() } }
        }
    }

    private func planCard(_ offer: PlanOffer, title: String, detail: String, suffix: String?, note: String?, id: String) -> some View {
        PilotCard {
            AdaptiveStack(spacing: 6) {
                Text(title).font(.headline)
                if !textSizeIsAccessibility { Spacer(minLength: 8) }
                Text(offer.displayPrice + (suffix.map { " \($0)" } ?? "")).font(.headline).foregroundStyle(PilotTheme.accent)
            }
            Text(detail).font(.subheadline)
            if let note { Text(note).font(.caption.bold()).foregroundStyle(PilotTheme.accent) }
            PrimaryButton(title: store.busy ? "Working…" : (offer.id == PlusProduct.pack ? "Buy" : (store.hasPlus ? "Switch plan" : "Subscribe")), icon: "arrow.right") { if let product = offer.product { Task { await store.purchase(product) } } }
                .disabled(store.busy)
                .accessibilityIdentifier(id)
        }
    }

    @Environment(\.dynamicTypeSize) private var textSize
    private var textSizeIsAccessibility: Bool { textSize.isAccessibilitySize }

    /// "Save 42%" for the yearly plan against twelve monthly payments.
    private var savings: String? {
        guard let monthly = store.monthly, let yearly = store.yearly, monthly.price > 0 else { return nil }
        let full = monthly.price * 12
        guard full > yearly.price else { return nil }
        let percent = NSDecimalNumber(decimal: (full - yearly.price) / full * 100).intValue
        return percent > 0 ? "Save \(percent)% compared with paying monthly" : nil
    }
}
