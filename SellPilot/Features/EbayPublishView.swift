import SwiftUI

/// Publishing a listing to eBay (sandbox only for now): choose the category, check the required item specifics, publish.
struct EbayPublishCard: View {
    @Bindable var workflow: SellingWorkflow
    let index: Int
    @State private var confirm = false

    private var draft: ListingDraft { workflow.item.listings[index] }
    private var sandbox: Bool { workflow.services.ebay?.environment != .production }
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
            Text("eBay needs a category and a few item details. SellPilot can suggest them from your item.").font(.caption).foregroundStyle(PilotTheme.muted)
            Button { Task { await workflow.prepareEbayListing(index) } } label: { Label(workflow.busy ? "Working…" : "Find category and details", systemImage: "wand.and.stars") }
                .buttonStyle(.bordered).disabled(workflow.busy).accessibilityIdentifier("ebayPrepare")
        } else {
            categorySection
            specificsSection
            policiesSection
            Button { confirm = true } label: { Label(workflow.busy ? "Publishing…" : sandbox ? "Publish test listing" : "Publish to eBay", systemImage: "paperplane.fill").frame(maxWidth: .infinity).padding(12) }
                .buttonStyle(.borderedProminent).tint(sandbox ? PilotTheme.accent : .red).disabled(workflow.busy || !missing.isEmpty).accessibilityIdentifier("ebayPublish")
            if !missing.isEmpty { Text("Still needed: \(missing.joined(separator: ", "))").font(.caption).foregroundStyle(.red) }
        }
    }
    .task { await workflow.loadEbayAspects(index); await workflow.loadEbayPolicies(index) }
    .confirmationDialog(sandbox ? "Create this test listing in the eBay Sandbox?" : "Publish this to REAL eBay?", isPresented: $confirm, titleVisibility: .visible) {
        Button(sandbox ? "Create test listing" : "Publish live listing", role: sandbox ? nil : .destructive) { Task { await workflow.publishToEbay(index) } }
    } message: { Text(Self.confirmationSummary(draft: draft, photoCount: draft.photoOrder.count, policies: workflow.ebayPolicies, live: !sandbox)) } }

    /// Everything the seller is about to put on eBay, in one place, before anything is sent.
    static func confirmationSummary(draft: ListingDraft, photoCount: Int, policies: EbaySellerPolicies, live: Bool) -> String {
        func name(_ id: String?, in list: [EbayPolicy]) -> String { list.first { $0.id == id }?.name ?? "default" }
        return [
            String(draft.title.prefix(80)),
            "\(draft.price.money) · \(draft.condition.rawValue) · \(photoCount) photo\(photoCount == 1 ? "" : "s")",
            "Category: \(draft.ebayCategoryName ?? "not chosen")",
            "Shipping: \(name(draft.ebayFulfillmentPolicyID, in: policies.fulfillment))",
            "Payment: \(name(draft.ebayPaymentPolicyID, in: policies.payment))",
            "Returns: \(name(draft.ebayReturnPolicyID, in: policies.returns))",
            live ? "This creates a LIVE listing that real buyers can purchase. eBay may charge listing and final value fees. You can end it from here." : "Sandbox only: nothing goes on real eBay.",
        ].joined(separator: "\n")
    }

    private var categorySection: some View { VStack(alignment: .leading, spacing: 6) {
        Text("eBay category").font(.caption.bold())
        Menu {
            ForEach(workflow.ebayCategoryChoices) { choice in Button(choice.path) { Task { await workflow.chooseEbayCategory(choice, index: index) } } }
            Button("Search again") { Task { await workflow.prepareEbayListing(index) } }
        } label: { HStack { Text(draft.ebayCategoryName ?? "Choose a category").multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption) }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10)) }
            .disabled(workflow.busy)
    } }

    private var policiesSection: some View { VStack(alignment: .leading, spacing: 8) {
        Text("Your eBay policies").font(.caption.bold())
        policyMenu("Shipping", selection: Binding(get: { draft.ebayFulfillmentPolicyID }, set: { workflow.item.listings[index].ebayFulfillmentPolicyID = $0 }), options: workflow.ebayPolicies.fulfillment)
        policyMenu("Payment", selection: Binding(get: { draft.ebayPaymentPolicyID }, set: { workflow.item.listings[index].ebayPaymentPolicyID = $0 }), options: workflow.ebayPolicies.payment)
        policyMenu("Returns", selection: Binding(get: { draft.ebayReturnPolicyID }, set: { workflow.item.listings[index].ebayReturnPolicyID = $0 }), options: workflow.ebayPolicies.returns)
        if let problem = workflow.ebayPoliciesProblem { Text(problem).font(.caption).foregroundStyle(.red) }
        Button("Reload policies") { Task { await workflow.loadEbayPolicies(index) } }.font(.caption).disabled(workflow.busy)
    } }

    private func policyMenu(_ title: String, selection: Binding<String?>, options: [EbayPolicy]) -> some View {
        Menu {
            ForEach(options) { option in Button(option.name) { selection.wrappedValue = option.id } }
        } label: {
            HStack { Text(title).foregroundStyle(PilotTheme.muted); Spacer(); Text(options.first { $0.id == selection.wrappedValue }?.name ?? (options.isEmpty ? (workflow.ebayPoliciesProblem == nil ? "Loading…" : "None") : "Choose")); Image(systemName: "chevron.up.chevron.down").font(.caption) }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }.disabled(options.isEmpty || workflow.busy)
    }

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
        Text(workflow.services.ebayIsLive ? "Publish to eBay" : "Publish to eBay Sandbox (test)").font(.headline)
        Text(workflow.services.ebayIsLive ? "Connect your eBay account to publish listings. In Settings, tap \"Connect eBay account\" under eBay." : "Connect your eBay account to publish. In Settings, tap \"Connect eBay Sandbox account\" and sign in as your sandbox seller.").font(.caption).foregroundStyle(PilotTheme.muted).foregroundStyle(PilotTheme.muted)
        Button { showSettings = true } label: { Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("ebayOpenSettings")
    }
    .sheet(isPresented: $showSettings, onDismiss: { workflow.reloadServices() }) { SettingsView(store: workflow.store) } }
}

/// The public app with eBay publishing switched off (the default): say how to turn it on instead of hiding the section.
struct EbayTurnedOffCard: View {
    @Bindable var workflow: SellingWorkflow
    @State private var showSettings = false

    var body: some View { PilotCard {
        Text("Publish to eBay").font(.headline)
        Text("Publishing from SellPilot is turned off. Turn it on in Settings under eBay (you'll connect your seller account and enter the ZIP code you ship from). Listings you publish are real: buyers can purchase them and eBay may charge fees.").font(.caption).foregroundStyle(PilotTheme.muted)
        Button { showSettings = true } label: { Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("ebayTurnedOffSettings")
    }
    .sheet(isPresented: $showSettings, onDismiss: { workflow.reloadServices() }) { SettingsView(store: workflow.store) } }
}

/// The public app could not load eBay's setup (usually no connection the first time it runs).
struct EbayUnavailableCard: View {
    @Bindable var workflow: SellingWorkflow
    @State private var retrying = false

    var body: some View { PilotCard {
        Text("Publish to eBay").font(.headline)
        Text("eBay isn't available right now. Check your internet connection and try again.").font(.caption).foregroundStyle(PilotTheme.muted)
        Button { Task { retrying = true; await EbayDeployment.refresh(); workflow.reloadServices(); retrying = false } } label: { Label(retrying ? "Trying…" : "Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.borderedProminent).disabled(retrying).accessibilityIdentifier("ebayTryAgain")
    } }
}

/// Which sandbox publishing settings are missing, so the screen can say so instead of hiding the section.
enum EbaySetupReport {
    typealias Loader = (APIKeyStore.Account) -> String?
    static func missing(live: Bool = false, zip: String = LiveSettings.shipFromZip, _ load: Loader = { APIKeyStore.load($0) }) -> [String] {
        var items: [String] = []
        if live {
            if load(.ebayAppID) == nil { items.append("Production App ID") }
            if load(.ebayRuName) == nil { items.append("Production redirect name (RuName)") }
            if !LiveSettings.isValidZip(zip) { items.append("Ship-from ZIP code") }
            if load(.ebayAuthProxy) == nil && load(.ebayCertID) == nil { items.append("Token server URL (or Production Cert ID)") }
        } else {
            if load(.ebaySandboxAppID) == nil { items.append("Sandbox App ID") }
            if load(.ebaySandboxRuName) == nil { items.append("Redirect name (RuName)") }
            if load(.ebayAuthProxy) == nil && load(.ebaySandboxCertID) == nil { items.append("Token server URL (or Sandbox Cert ID)") }
        }
        return items
    }
}

struct EbaySetupCard: View {
    var missing: [String]
    @Bindable var workflow: SellingWorkflow
    @State private var showSettings = false

    var body: some View { PilotCard {
        Text(workflow.services.ebayIsLive ? "Publish to eBay" : "Publish to eBay Sandbox (test)").font(.headline)
        Text("Not set up on this device yet. Still needed in Settings: \(missing.joined(separator: ", ")). Then connect your eBay account.").font(.caption).foregroundStyle(PilotTheme.muted)
        Button { showSettings = true } label: { Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity).padding(12) }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("ebaySetupSettings")
    }
    .sheet(isPresented: $showSettings, onDismiss: { workflow.reloadServices() }) { SettingsView(store: workflow.store) } }
}
