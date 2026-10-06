import SwiftUI
struct WorkflowView: View {
    @State var workflow: SellingWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var confirmActive = false
    @State private var showSold = false
    @State private var soldPrice = ""
    private let titles = ["Photograph", "Confirm", "Details", "Market", "Price", "Places", "Photos", "Ready"]
    var body: some View { NavigationStack {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            HStack { Text("\(workflow.item.workflowStep + 1) OF 8").font(.caption.bold()).tracking(2); Spacer(); Text("Saved locally · Mock AI").font(.caption).foregroundStyle(.secondary) }
            ProgressView(value: Double(workflow.item.workflowStep + 1), total: 8)
            if workflow.item.status == .sold { PilotCard { Label("Sold for \((workflow.item.soldPrice ?? 0).money)", systemImage: "checkmark.seal.fill").font(.title2.bold()); Text(workflow.item.soldDate?.formatted() ?? "") } }
            else if workflow.item.status == .active { PilotCard { Label("Tracking as Active", systemImage: "tag.fill"); Text("You confirmed this item was published externally.").font(.caption); PrimaryButton(title: "Mark Sold", icon: "checkmark") { soldPrice = String(workflow.item.askingPrice); showSold = true } } }
            Group { switch workflow.item.workflowStep {
            case 0: CaptureView(workflow: workflow)
            case 1: IdentificationView(workflow: workflow)
            case 2: NotesView(workflow: workflow)
            case 3: MarketView(item: workflow.item)
            case 4: PricingView(workflow: workflow)
            case 5: MarketplaceView(workflow: workflow)
            case 6: EnhancementView(workflow: workflow)
            default: ListingReviewView(workflow: workflow)
            } }.disabled(workflow.item.status == .sold || workflow.item.status == .archived)
            if workflow.item.workflowStep == 7 && (workflow.item.status == .ready || workflow.item.status == .draft) {
                PrimaryButton(title: "I published it — mark Active", icon: "checkmark") { confirmActive = true }.accessibilityIdentifier("markActive")
                Button("Save as Draft") { workflow.item.status = .draft; if workflow.save() { dismiss() } }.frame(maxWidth: .infinity).padding()
            }
            if workflow.item.workflowStep == 7 && workflow.item.status != .archived { Button("Archive item") { workflow.item.status = .archived; if workflow.save() { dismiss() } }.foregroundStyle(.secondary) }
        }.padding(22) }.id(workflow.item.workflowStep).scrollDismissesKeyboard(.interactively).background(PilotTheme.background)
            .safeAreaInset(edge: .bottom) {
                if workflow.item.workflowStep < 7 {
                    PrimaryButton(title: workflow.busy ? "Working…" : nextTitle) { Task { await workflow.advance() } }
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
            .onChange(of: workflow.item) { _, _ in workflow.save() }
            .alert("Could not complete action", isPresented: Binding(get: { workflow.error != nil }, set: { if !$0 { workflow.error = nil } })) { Button("OK") { workflow.error = nil } } message: { Text(workflow.error ?? "") }
            .alert("Prototype publishing", isPresented: Binding(get: { workflow.notice != nil }, set: { if !$0 { workflow.notice = nil } })) { Button("OK") { workflow.notice = nil } } message: { Text(workflow.notice ?? "") }
            .confirmationDialog("Confirm you published this item on your chosen marketplaces.", isPresented: $confirmActive, titleVisibility: .visible) { Button("Confirm published") { do { try workflow.activate(); dismiss() } catch { workflow.error = error.localizedDescription } } }
            .alert("Record the sale", isPresented: $showSold) { TextField("Sold price", text: $soldPrice).keyboardType(.decimalPad); Button("Save sale") { guard let price = Double(soldPrice) else { workflow.error = "Enter a valid sold price."; return }; Task { await workflow.markSold(price: price); if workflow.error == nil { dismiss() } } }; Button("Cancel", role: .cancel) {} } message: { Text("Enter the amount you actually received.") }
    } }
    private var nextTitle: String { ["Analyze photos", "Confirm item", "Research my item", "Choose my price", "Find the best places", "Review photos", "Generate my listings", ""][workflow.item.workflowStep] }
}
