import SwiftUI

/// Publishing a listing to eBay (sandbox only for now): choose the category, check the required item specifics, publish.
struct EbayPublishCard: View {
    @Bindable var workflow: SellingWorkflow
    let index: Int
    @State private var confirm = false

    private var draft: ListingDraft { workflow.item.listings[index] }
    private var sandbox: Bool { workflow.services.ebay?.environment == .sandbox }
    private var requiredAspects: [EbayAspect] { workflow.ebayAspects.filter(\.required) }
    private var missing: [String] { EbaySpecifics.missing(workflow.ebayAspects, in: draft.itemSpecifics) }

    var body: some View { PilotCard {
        Text(sandbox ? "Publish to eBay Sandbox (test)" : "Publish to eBay").font(.headline)
        if sandbox { Text("TEST ONLY · Creates a listing in eBay's sandbox. Nothing is posted to real eBay.").font(.caption.bold()).foregroundStyle(PilotTheme.accent) }
        if let id = draft.ebayListingID, let url = draft.ebayListingURL {
            Label("Created on eBay\(draft.ebayEnvironment == "sandbox" ? " Sandbox" : "") · \(id)", systemImage: "checkmark.seal.fill").font(.subheadline)
            Link("View on eBay", destination: url)
            Button("End listing", role: .destructive) { Task { await workflow.endEbayListing(index) } }.buttonStyle(.bordered).disabled(workflow.busy)
        } else if draft.ebayCategoryID == nil {
            Text("eBay needs a category and a few item details. SellPilot can suggest them from your item.").font(.caption).foregroundStyle(.secondary)
            Button { Task { await workflow.prepareEbayListing(index) } } label: { Label(workflow.busy ? "Working…" : "Find category and details", systemImage: "wand.and.stars") }
                .buttonStyle(.bordered).disabled(workflow.busy).accessibilityIdentifier("ebayPrepare")
        } else {
            categorySection
            specificsSection
            Button { confirm = true } label: { Label(workflow.busy ? "Publishing…" : sandbox ? "Publish test listing" : "Publish to eBay", systemImage: "paperplane.fill").frame(maxWidth: .infinity).padding(12) }
                .buttonStyle(.borderedProminent).disabled(workflow.busy || !missing.isEmpty).accessibilityIdentifier("ebayPublish")
            if !missing.isEmpty { Text("Still needed: \(missing.joined(separator: ", "))").font(.caption).foregroundStyle(.red) }
        }
    }
    .task { await workflow.loadEbayAspects(index) }
    .confirmationDialog(sandbox ? "Create this test listing in the eBay Sandbox?" : "Publish this listing to eBay?", isPresented: $confirm, titleVisibility: .visible) {
        Button(sandbox ? "Create test listing" : "Publish") { Task { await workflow.publishToEbay(index) } }
    } message: { Text(sandbox ? "This only creates a test listing. It does not go on real eBay." : "This creates a real listing at \(draft.price.money).") } }

    private var categorySection: some View { VStack(alignment: .leading, spacing: 6) {
        Text("eBay category").font(.caption.bold())
        Menu {
            ForEach(workflow.ebayCategoryChoices) { choice in Button(choice.path) { Task { await workflow.chooseEbayCategory(choice, index: index) } } }
            Button("Search again") { Task { await workflow.prepareEbayListing(index) } }
        } label: { HStack { Text(draft.ebayCategoryName ?? "Choose a category"); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption) }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)) }
            .disabled(workflow.busy)
    } }

    private var specificsSection: some View { VStack(alignment: .leading, spacing: 8) {
        Text("Required eBay details").font(.caption.bold())
        ForEach(requiredAspects, id: \.name) { aspect in
            let value = Binding(get: { draft.itemSpecifics.first { $0.key.caseInsensitiveCompare(aspect.name) == .orderedSame }?.value ?? "" }, set: { workflow.item.listings[index].itemSpecifics[aspect.name] = $0 })
            VStack(alignment: .leading, spacing: 4) {
                Text(aspect.name).font(.caption).foregroundStyle(value.wrappedValue.isEmpty ? .red : .secondary)
                if aspect.selectionOnly && !aspect.values.isEmpty && aspect.values.count <= 30 {
                    Picker(aspect.name, selection: value) { Text("Choose…").tag(""); ForEach(aspect.values, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).labelsHidden()
                } else { TextField(aspect.name, text: value).textFieldStyle(.roundedBorder) }
            }
        }
    } }
}

/// Shown instead of the publish section when eBay is set up but nobody is signed in, so the section never just vanishes.
struct EbayConnectCard: View {
    @Bindable var workflow: SellingWorkflow
    @State private var showSettings = false

    var body: some View { PilotCard {
        Text("Publish to eBay Sandbox (test)").font(.headline)
        Text("Connect your eBay account to publish. In Settings, tap \"Connect eBay Sandbox account\" and sign in as your sandbox seller.").font(.caption).foregroundStyle(.secondary)
        Button { showSettings = true } label: { Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("ebayOpenSettings")
    }
    .sheet(isPresented: $showSettings, onDismiss: { workflow.reloadServices() }) { SettingsView() } }
}
