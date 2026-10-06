import SwiftUI
struct MarketView: View {
    var item: SellItem
    @State private var filter: ComparableStatus = .sold
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Market Snapshot").font(.largeTitle.bold())
        Text("SIMULATED RESEARCH · No live sales data").font(.caption.bold()).foregroundStyle(PilotTheme.accent)
        if let price = item.pricing { PilotCard {
            HStack { stat("Active asking", "\(item.comparables.filter { $0.status == .active }.count)"); Spacer(); stat("Sold comparables", "\(item.comparables.filter { $0.status == .sold }.count)") }
            Divider(); stat("Estimated sold range", "\(price.soldLow.money)–\(price.soldHigh.money)")
            HStack { stat("Median sold", price.soldMedian.money); Spacer(); stat("Median asking", price.askingMedian.money) }
            Text(price.dataSourceSummary).font(.caption).foregroundStyle(.secondary)
        } }
        Picker("Comparables", selection: $filter) { Text("Sold comparables").tag(ComparableStatus.sold); Text("Active asking").tag(ComparableStatus.active) }.pickerStyle(.segmented)
        ForEach(item.comparables.filter { $0.status == filter }) { comp in PilotCard { HStack { Image(systemName: "photo").font(.title).foregroundStyle(.secondary); VStack(alignment: .leading) { Text(comp.title).font(.headline); Text("\(comp.marketplace.rawValue) · \(comp.condition.rawValue)").font(.caption) }; Spacer(); Text(comp.price.money).bold() }; HStack { Text(comp.status.rawValue); Spacer(); Text(comp.date, style: .date) }.font(.caption).foregroundStyle(.secondary) } }
    } }
    private func stat(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()) } }
}
struct PricingView: View {
    @Bindable var workflow: SellingWorkflow
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("What should you ask?").font(.largeTitle.bold())
        Text("Three ways to approach your sale. These are suggested asking prices from mock data.").foregroundStyle(.secondary)
        if let pricing = workflow.item.pricing {
            ForEach(PricingStrategy.allCases, id: \.self) { strategy in Button { workflow.item.pricingStrategy = strategy; workflow.item.askingPrice = pricing.price(for: strategy) } label: { PilotCard {
                HStack { Text(strategy.rawValue).font(.headline); Spacer(); Image(systemName: workflow.item.pricingStrategy == strategy ? "checkmark.circle.fill" : "circle").foregroundStyle(PilotTheme.accent) }
                Text(pricing.price(for: strategy).money).font(.system(size: 40, weight: .bold, design: .rounded))
                Text(explanation(strategy)).font(.subheadline).foregroundStyle(.secondary)
            }.overlay(RoundedRectangle(cornerRadius: 22).stroke(workflow.item.pricingStrategy == strategy ? PilotTheme.accent : .clear, lineWidth: 2)) }.buttonStyle(.plain) }
            PilotCard { Text("Your asking price").font(.headline); TextField("Asking price", value: $workflow.item.askingPrice, format: .number).keyboardType(.decimalPad); Text(pricing.rationale).font(.caption).foregroundStyle(.secondary) }
        }
    } }
    private func explanation(_ strategy: PricingStrategy) -> String { switch strategy { case .fast: "Below recent comparable sales to attract price-sensitive buyers. A faster sale is not guaranteed."; case .recommended: "A balance between comparable sales and active competition."; case .maximize: "More room to negotiate, with potentially more time to find a buyer." } }
}
struct MarketplaceView: View {
    @Bindable var workflow: SellingWorkflow
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Best Places to Sell").font(.largeTitle.bold()); Text("Likely fit based on simulated category recommendations. Select one or more.").foregroundStyle(.secondary)
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
struct EnhancementView: View {
    @Bindable var workflow: SellingWorkflow
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Better photos.\nSame product.").font(.largeTitle.bold()); Text("Simulated presentation previews only. No clutter removal or generated environments. Product pixels and visible defects stay unchanged; originals are preserved.").foregroundStyle(.secondary)
        ForEach(workflow.item.orderedPhotos) { photo in PilotCard {
            HStack { VStack { PhotoView(photo: photo, height: 150, original: true); Text("Original").font(.caption) }; VStack { PhotoView(photo: photo, height: 150); Text("Mock preview").font(.caption) } }
            Picker("Presentation", selection: Binding(get: { photo.enhancement.style }, set: { style in Task { await workflow.enhance(photo.id, style: style) } })) { ForEach(EnhancementStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Text("Export uses original images. \(photo.enhancement.style == .lifestyle ? "Lifestyle concept: " + (workflow.item.category == "Furniture" ? "living room" : workflow.item.category == "Camping equipment" ? "campsite" : "organized workspace") : photo.enhancement.style.rawValue)").font(.caption).foregroundStyle(.secondary)
        } }
    } }
}
