import SwiftUI
struct WorkflowView: View {
    @State var workflow: SellingWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmActive = false
    @State private var askConsent = false
    @State private var showSettings = false
    @State private var showSold = false
    @State private var soldPrice = ""
    private var hasEbayListing: Bool { workflow.item.listings.contains { $0.ebayListingID != nil } }
    private var onEbay: Bool { hasEbayListing && workflow.item.status == .active }
    private let titles = ["Photograph", "Confirm", "Price & places", "Ready"]
    var body: some View { NavigationStack {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            AdaptiveStack { Text("\(workflow.item.workflowStep + 1) OF \(SellItem.lastStep + 1)").font(.caption.bold()).tracking(2); Spacer(minLength: 8); Text(workflow.services.usesLiveIdentification || workflow.services.usesLivePricing ? "Saved on this device" : "Saved on this device · Demo data").font(.caption).foregroundStyle(PilotTheme.muted) }
            ProgressView(value: Double(workflow.item.workflowStep + 1), total: Double(SellItem.lastStep + 1)).accessibilityHidden(true)
            if workflow.item.status == .sold { PilotCard { Label("Sold for \((workflow.item.soldPrice ?? 0).money)", systemImage: "checkmark.seal.fill").font(.title2.bold()); Text(workflow.item.soldDate?.formatted() ?? "") } }
            else if workflow.item.status == .active { PilotCard { Label(onEbay ? "Live on eBay" : "Tracking as Active", systemImage: "tag.fill"); Text(onEbay ? "Published to eBay from SellPilot." : "You confirmed this item was published externally.").font(.caption); PrimaryButton(title: "Mark Sold", icon: "checkmark") { soldPrice = String(workflow.item.askingPrice); showSold = true } } }
            Group { switch workflow.item.workflowStep {
            case 0: CaptureView(workflow: workflow)
            case 1: VStack(alignment: .leading, spacing: 28) { IdentificationView(workflow: workflow); NotesView(workflow: workflow) }
            case 2: VStack(alignment: .leading, spacing: 28) { PricingView(workflow: workflow); MarketplaceView(workflow: workflow); if !workflow.item.comparables.isEmpty { DisclosureGroup("Market data behind this price") { MarketView(item: workflow.item).padding(.top, 8) } } }
            default: ListingReviewView(workflow: workflow)
            } }.disabled(workflow.item.status == .sold || workflow.item.status == .archived)
            if workflow.item.workflowStep == SellItem.lastStep && (workflow.item.status == .ready || workflow.item.status == .draft) {
                if !hasEbayListing { PrimaryButton(title: workflow.services.ebaySetup == .notConfigured ? "I published it — mark Active" : "I posted it somewhere else — mark Active", icon: "checkmark") { confirmActive = true }.accessibilityIdentifier("markActive") }
                Button { Task { await workflow.refreshMarketPrices() } } label: { Label("Refresh market prices", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.bordered).disabled(workflow.busy || workflow.item.listings.contains { $0.ebayListingID != nil })
                Button("Save as Draft") { workflow.item.status = .draft; if workflow.save() { dismiss() } }.frame(maxWidth: .infinity).padding()
            }
            if workflow.item.workflowStep == SellItem.lastStep && workflow.item.status != .archived { Button("Archive item") { workflow.item.status = .archived; if workflow.save() { dismiss() } }.foregroundStyle(PilotTheme.muted) }
        }.padding(22) }.id(workflow.item.workflowStep).scrollDismissesKeyboard(.interactively).background(PilotTheme.background)
            .safeAreaInset(edge: .bottom) {
                if workflow.item.workflowStep < SellItem.lastStep {
                    PrimaryButton(title: workflow.busy ? "Working…" : nextTitle) {
                        // Photos go to an AI service, so ask once before the first analysis.
                        if workflow.item.workflowStep == 0 && workflow.services.usesLiveIdentification && !AIConsent.given { askConsent = true }
                        else { Task { await workflow.advance() } }
                    }
                        .disabled(workflow.busy || (workflow.item.workflowStep == 0 && workflow.item.photos.isEmpty))
                        .padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial)
                }
            }
            .navigationTitle(titles[workflow.item.workflowStep]).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if workflow.item.workflowStep > 0 && (workflow.item.status == .draft || workflow.item.status == .ready) { Button { workflow.item.workflowStep -= 1; workflow.save() } label: { Image(systemName: "chevron.left") }.disabled(workflow.busy) } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { if workflow.save() { dismiss() } }.disabled(workflow.busy) }
            }
            .interactiveDismissDisabled(workflow.busy)
            .confirmationDialog("Send your photos to an AI service?", isPresented: $askConsent, titleVisibility: .visible) {
                Button("Allow and analyze") { AIConsent.given = true; Task { await workflow.advance() } }
                Button("I'll enter the details myself") { workflow.skipIdentification() }
                Button("Cancel", role: .cancel) {}
            } message: { Text((workflow.services.identification.disclosure ?? "") + " If you publish to eBay, your item description may also be sent to fill in item details. You can change this in Settings.") }
            .onChange(of: workflow.item) { _, _ in workflow.save() }
            .alert("Could not complete action", isPresented: Binding(get: { workflow.error != nil }, set: { if !$0 { workflow.error = nil; workflow.reconnectNeeded = false } })) {
                if workflow.reconnectNeeded { Button("Open Settings") { workflow.error = nil; workflow.reconnectNeeded = false; showSettings = true } }
                Button(workflow.reconnectNeeded ? "Not now" : "OK", role: .cancel) { workflow.error = nil; workflow.reconnectNeeded = false }
            } message: { Text(workflow.error ?? "") }
            .sheet(isPresented: $showSettings, onDismiss: { workflow.reloadServices() }) { SettingsView(store: workflow.store) }
            .alert("SellPilot", isPresented: Binding(get: { workflow.notice != nil }, set: { if !$0 { workflow.notice = nil } })) { Button("OK") { workflow.notice = nil } } message: { Text(workflow.notice ?? "") }
            .confirmationDialog("Confirm you published this item on your chosen marketplaces.", isPresented: $confirmActive, titleVisibility: .visible) { Button("Confirm published") { do { try workflow.activate(); dismiss() } catch { workflow.error = error.localizedDescription } } }
            .alert("Record the sale", isPresented: $showSold) { TextField("Sold price", text: $soldPrice).keyboardType(.decimalPad); Button("Save sale") { guard let price = Double(soldPrice) else { workflow.error = "Enter a valid sold price."; return }; Task { await workflow.markSold(price: price); if workflow.error == nil { dismiss() } } }; Button("Cancel", role: .cancel) {} } message: { Text("Enter the amount you actually received.") }
    } }
    private var nextTitle: String { ["Analyze photos", "See pricing", "Generate my listings", ""][workflow.item.workflowStep] }
}
