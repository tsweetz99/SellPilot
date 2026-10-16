import SwiftUI
struct MarketView: View {
    var item: SellItem
    @State private var filter: ComparableStatus = .sold
    private var hasSold: Bool { item.comparables.contains { $0.status == .sold } }
    private var shown: ComparableStatus { hasSold ? filter : .active }
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Market snapshot").font(.title2.bold())
        if item.pricing?.source == nil { Text("SIMULATED RESEARCH · No live sales data").font(.caption.bold()).foregroundStyle(PilotTheme.accent) }
        else { Text("LIVE EBAY ASKING PRICES · Not sold prices").font(.caption.bold()).foregroundStyle(PilotTheme.accent) }
        if let price = item.pricing { PilotCard {
            HStack { stat("Active asking", "\(item.comparables.filter { $0.status == .active }.count)"); Spacer(); if hasSold { stat("Sold comparables", "\(item.comparables.filter { $0.status == .sold }.count)") } }
            Divider(); stat(price.source == nil ? "Estimated sold range" : "Estimated sale range", "\(price.soldLow.money)–\(price.soldHigh.money)")
            HStack { stat(price.source == nil ? "Median sold" : "Estimated sale price", price.soldMedian.money); Spacer(); stat("Median asking", price.askingMedian.money) }
            Text(price.dataSourceSummary).font(.caption).foregroundStyle(.secondary)
        } }
        if hasSold { Picker("Comparables", selection: $filter) { Text("Sold comparables").tag(ComparableStatus.sold); Text("Active asking").tag(ComparableStatus.active) }.pickerStyle(.segmented) }
        if item.comparables.isEmpty { Text("No comparable listings were found.").foregroundStyle(.secondary) }
        ForEach(item.comparables.filter { $0.status == shown }) { comp in PilotCard { HStack { Image(systemName: "photo").font(.title).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(comp.title).font(.headline).lineLimit(2); Text("\(comp.marketplace.rawValue) · \(comp.condition.rawValue)").font(.caption) }; Spacer(); Text(comp.price.money).bold() }; HStack { Text(comp.status.rawValue); Spacer(); if let url = comp.url { Link("View listing", destination: url) } else { Text(comp.date, style: .date) } }.font(.caption).foregroundStyle(.secondary) } }
    } }
    private func stat(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()) } }
}
struct PricingView: View {
    @Bindable var workflow: SellingWorkflow
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("What should you ask?").font(.largeTitle.bold())
        if workflow.item.pricing?.source != nil { Text("LIVE EBAY ASKING PRICES · Not sold prices").font(.caption.bold()).foregroundStyle(PilotTheme.accent) }
        Text(workflow.item.pricing == nil ? "No market data is available for this item." : workflow.item.pricing?.source == nil ? "Three ways to approach your sale. These are suggested asking prices from mock data." : "Three ways to approach your sale, based on similar active eBay listings.").foregroundStyle(.secondary)
        if let pricing = workflow.item.pricing {
            ForEach(PricingStrategy.allCases, id: \.self) { strategy in Button { workflow.item.pricingStrategy = strategy; workflow.item.askingPrice = pricing.price(for: strategy) } label: { PilotCard {
                HStack { Text(strategy.rawValue).font(.headline); Spacer(); Image(systemName: workflow.item.pricingStrategy == strategy ? "checkmark.circle.fill" : "circle").foregroundStyle(PilotTheme.accent) }
                Text(pricing.price(for: strategy).money).font(.system(size: 40, weight: .bold, design: .rounded))
                Text(explanation(strategy)).font(.subheadline).foregroundStyle(.secondary)
            }.overlay(RoundedRectangle(cornerRadius: 22).stroke(workflow.item.pricingStrategy == strategy ? PilotTheme.accent : .clear, lineWidth: 2)) }.buttonStyle(.plain) }
            PilotCard { Text("Your asking price").font(.headline); TextField("Asking price", value: $workflow.item.askingPrice, format: .number).keyboardType(.decimalPad); Text(pricing.rationale).font(.caption).foregroundStyle(.secondary) }
        } else {
            PilotCard { Text("Your asking price").font(.headline); TextField("Asking price", value: $workflow.item.askingPrice, format: .number).keyboardType(.decimalPad); Text("Check similar listings yourself and enter the price you want.").font(.caption).foregroundStyle(.secondary) }
        }
        Button { Task { await workflow.refreshMarketPrices() } } label: { Label(workflow.busy ? "Refreshing…" : "Refresh market prices", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.bordered).disabled(workflow.busy).accessibilityIdentifier("refreshPrices")
    } }
    private func explanation(_ strategy: PricingStrategy) -> String { switch strategy { case .fast: "Below recent comparable sales to attract price-sensitive buyers. A faster sale is not guaranteed."; case .recommended: "A balance between comparable sales and active competition."; case .maximize: "More room to negotiate, with potentially more time to find a buyer." } }
}
struct MarketplaceView: View {
    @Bindable var workflow: SellingWorkflow
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Best places to sell").font(.title2.bold()); Text("Likely fit based on simulated category recommendations. Select one or more.").foregroundStyle(.secondary)
        ForEach(workflow.item.recommendations) { recommendation in Button { toggle(recommendation.marketplace) } label: { PilotCard {
            HStack { Text("\(recommendation.rank). \(recommendation.marketplace.rawValue)").font(.headline); Spacer(); Image(systemName: workflow.item.selectedMarketplaces.contains(recommendation.marketplace) ? "checkmark.circle.fill" : "circle") }
            Text(recommendation.rank == 1 ? "Best fit" : recommendation.rank == 2 ? "Good fit" : "Fair fit").font(.caption.bold()).foregroundStyle(PilotTheme.accent)
            ForEach(recommendation.rationale, id: \.self) { Text("• \($0)").font(.subheadline) }
            Text(recommendation.shippingFit).font(.caption); Text(recommendation.sellerFeeConsideration).font(.caption).foregroundStyle(.secondary)
        } }.buttonStyle(.plain) }
        DisclosureGroup("Choose another marketplace") { ForEach(Marketplace.allCases.filter { market in !workflow.item.recommendations.contains { $0.marketplace == market } }) { market in Toggle(market.rawValue, isOn: Binding(get: { workflow.item.selectedMarketplaces.contains(market) }, set: { _ in toggle(market) })).padding(.vertical, 6) } }
    } }
    private func toggle(_ market: Marketplace) { if workflow.item.selectedMarketplaces.contains(market) { workflow.item.selectedMarketplaces.removeAll { $0 == market } } else { workflow.item.selectedMarketplaces.append(market) } }
}
