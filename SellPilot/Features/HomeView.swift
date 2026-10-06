import SwiftUI
struct HomeView: View {
    @Bindable var store: ItemStore
    @State private var selectedItem: SellItem?
    private let services = AppServices()
    var body: some View {
        TabView {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 24) {
                    HStack { Image(systemName: "paperplane.fill").foregroundStyle(PilotTheme.accent); Text("SELLPILOT").font(.headline).tracking(3); Spacer(); Text("MVP • MOCK AI").font(.caption2.bold()).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 10) { Text("Less effort.\nMore sold.").font(.system(size: 42, weight: .bold, design: .rounded)); Text("Give your unused things a fresh start.").foregroundStyle(.secondary) }
                    PrimaryButton(title: "Sell Something", icon: "camera.fill") { let item = SellItem(); if store.save(item) { selectedItem = item } }.accessibilityIdentifier("sellSomething")
                    HStack { Image(systemName: "sparkles"); Text("Photograph. Confirm. Price. Publish.") }.font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        metric("Active listings", "\(store.items.filter { $0.status == .active }.count)", "tag")
                        metric("Sold items", "\(store.items.filter { $0.status == .sold }.count)", "checkmark.circle")
                        metric("Drafts", "\(drafts.count)", "pencil")
                        metric("Recorded sales", store.items.reduce(0) { $0 + ($1.soldPrice ?? 0) }.money, "dollarsign.circle")
                    }
                    Text("Recent items").font(.title2.bold())
                    if store.items.isEmpty { PilotCard { Image(systemName: "camera.viewfinder").font(.largeTitle).foregroundStyle(PilotTheme.accent); Text("Your next sale starts with a photo.").font(.headline); Text("Add an item to get suggested prices and a listing you can share.").foregroundStyle(.secondary) } }
                    ForEach(store.items.prefix(5)) { item in Button { selectedItem = item } label: { ItemCard(item: item) }.buttonStyle(.plain) }
                }.padding(22) }.background(PilotTheme.background).toolbar(.hidden, for: .navigationBar)
            }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { InventoryView(store: store, onSelect: { selectedItem = $0 }) }.tabItem { Label("My Stuff", systemImage: "square.grid.2x2.fill") }
        }.sheet(item: $selectedItem) { item in WorkflowView(workflow: SellingWorkflow(item: item, store: store, services: services)) }
            .alert("Storage issue", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var drafts: [SellItem] { store.items.filter { $0.status == .draft || $0.status == .ready } }
    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View { PilotCard { Image(systemName: symbol).foregroundStyle(PilotTheme.accent); Text(value).font(.title.bold()); Text(title).font(.caption).foregroundStyle(.secondary) } }
}
struct InventoryView: View {
    var store: ItemStore; var onSelect: (SellItem) -> Void
    @State private var filter = "Active"
    private let filters = ["Active", "Sold", "Drafts", "Archived"]
    private var items: [SellItem] { store.items.filter { item in switch filter { case "Active": item.status == .active; case "Sold": item.status == .sold; case "Archived": item.status == .archived; default: item.status == .draft || item.status == .ready } } }
    var body: some View { ScrollView { VStack(spacing: 16) {
        Picker("Status", selection: $filter) { ForEach(filters, id: \.self) { Text($0) } }.pickerStyle(.segmented)
        if items.isEmpty { ContentUnavailableView("No \(filter.lowercased()) yet", systemImage: "tag", description: Text("Your items will appear here as you sell.")) }
        ForEach(items) { item in Button { onSelect(item) } label: { ItemCard(item: item) }.buttonStyle(.plain) }
    }.padding(20) }.background(PilotTheme.background).navigationTitle("My Stuff") }
}
