import SwiftUI
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
struct SharePayload: Identifiable { var id = UUID(); var items: [Any] }
struct ListingReviewView: View {
    @Bindable var workflow: SellingWorkflow
    @State private var market: Marketplace?
    @State private var share: SharePayload?
    @State private var copied = false
    private var index: Int? { workflow.item.listings.firstIndex { $0.marketplace == (market ?? workflow.item.listings.first?.marketplace) } }
    var body: some View { VStack(alignment: .leading, spacing: 18) {
        Text("Your Listing Is Ready").font(.largeTitle.bold())
        Text("\(workflow.item.pricingStrategy.rawValue) · Review the facts, photos, and price before posting.").foregroundStyle(.secondary)
        if !workflow.item.listings.isEmpty {
            Picker("Marketplace listing", selection: Binding(get: { market ?? workflow.item.listings[0].marketplace }, set: { market = $0 })) { ForEach(workflow.item.listings) { draft in Text(draft.marketplace.rawValue).tag(draft.marketplace) } }.pickerStyle(.menu)
        }
        if let index {
            editor(index)
            PilotCard {
                Text("Publish / Export").font(.headline)
                Text("Export prepares copy and original photos. You post the listing yourself; mock publishing never posts to a marketplace.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Copy title") { UIPasteboard.general.string = workflow.item.listings[index].title; copied = true }; Button("Copy description") { UIPasteboard.general.string = workflow.item.listings[index].description; copied = true } }.buttonStyle(.bordered)
                Button("Copy full listing") { UIPasteboard.general.string = workflow.item.listings[index].fullText; copied = true }.buttonStyle(.bordered)
                if copied { Text("Copied to clipboard").font(.caption).foregroundStyle(PilotTheme.accent) }
                PrimaryButton(title: workflow.item.listings[index].marketplace == .facebook ? "Prepare Facebook Listing" : "Export listing package", icon: "square.and.arrow.up") { Task { await export(index, photosOnly: false) } }
                Button("Share original photos") { Task { await export(index, photosOnly: true) } }.buttonStyle(.bordered)
                if workflow.item.listings[index].marketplace == .ebay { Button("Publish to eBay (mock)") { Task { await workflow.mockPublish(index) } }.buttonStyle(.bordered) }
                if workflow.item.listings[index].mockPublishReference != nil { Text("Mock publish recorded. No listing was posted.").font(.caption) }
            }
        }
    }.sheet(item: $share) { payload in ShareSheet(items: payload.items) } }
    private func editor(_ index: Int) -> some View { PilotCard {
        Text("Listing title").font(.caption.bold()); TextField("Title", text: $workflow.item.listings[index].title, axis: .vertical)
        Text("Description").font(.caption.bold()); TextEditor(text: $workflow.item.listings[index].description).frame(minHeight: 190)
        Text("Asking price (USD)").font(.caption.bold()); TextField("Asking price", value: $workflow.item.listings[index].price, format: .number).keyboardType(.decimalPad)
        Picker("Condition", selection: $workflow.item.listings[index].condition) { ForEach(ItemCondition.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        Text("Category").font(.caption.bold()); TextField("Category", text: $workflow.item.listings[index].category)
        Text("Tags").font(.caption.bold()); TextField("Tags, comma separated", text: Binding(get: { workflow.item.listings[index].keywords.joined(separator: ", ") }, set: { workflow.item.listings[index].keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
        DisclosureGroup("Item specifics") { ForEach(workflow.item.listings[index].itemSpecifics.keys.sorted(), id: \.self) { key in TextField(key, text: Binding(get: { workflow.item.listings[index].itemSpecifics[key] ?? "" }, set: { workflow.item.listings[index].itemSpecifics[key] = $0 })).textFieldStyle(.roundedBorder).padding(.vertical, 4) } }
        Text("Shipping notes").font(.caption.bold()); TextField("Shipping notes", text: $workflow.item.listings[index].shippingNotes, axis: .vertical)
        Text("Pickup notes").font(.caption.bold()); TextField("Pickup notes", text: $workflow.item.listings[index].localPickupNotes, axis: .vertical)
        Text("Photo order").font(.headline)
        ForEach(Array(workflow.item.listings[index].photoOrder.enumerated()), id: \.element) { position, id in
            if let photo = workflow.item.photos.first(where: { $0.id == id }) { HStack {
                PhotoView(photo: photo, height: 70, original: true).frame(width: 90); Text(position == 0 ? "Cover photo" : "Photo \(position + 1)"); Spacer()
                Button { workflow.item.listings[index].photoOrder.swapAt(position, position - 1) } label: { Image(systemName: "arrow.up") }.disabled(position == 0).accessibilityLabel("Move listing photo earlier")
                Button { workflow.item.listings[index].photoOrder.swapAt(position, position + 1) } label: { Image(systemName: "arrow.down") }.disabled(position == workflow.item.listings[index].photoOrder.count - 1).accessibilityLabel("Move listing photo later")
            }.buttonStyle(.bordered) }
        }
    } }
    private func export(_ index: Int, photosOnly: Bool) async {
        do {
            let prepared = try await workflow.services.publishing.prepareListing(workflow.item.listings[index], item: workflow.item)
            let files = try ListingExportService().export(prepared)
            workflow.item.listings[index].preparedAt = Date(); workflow.save()
            share = SharePayload(items: photosOnly ? Array(files.dropFirst(2)) : files)
        } catch { workflow.error = error.localizedDescription }
    }
}
