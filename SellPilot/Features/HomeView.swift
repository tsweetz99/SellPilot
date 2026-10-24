import SwiftUI
enum InventoryFilter: String, CaseIterable { case active = "Active", sold = "Sold", drafts = "Drafts", archived = "Archived" }
struct HomeView: View {
    enum Tab { case home, stuff }
    @Bindable var store: ItemStore
    @State private var tab = Tab.home
    @State private var inventoryFilter = InventoryFilter.active
    @State private var selectedItem: SellItem?
    @State private var showSettings = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 10) { Text("Less effort.\nMore sold.").font(.system(.largeTitle, design: .rounded).weight(.bold)).minimumScaleFactor(0.7); Text("Give your unused things a fresh start.").foregroundStyle(PilotTheme.muted) }
                    PrimaryButton(title: "Sell Something", icon: "camera.fill") { let item = SellItem(); if store.save(item) { selectedItem = item } }.accessibilityIdentifier("sellSomething")
                    HStack { Image(systemName: "sparkles"); Text("Photograph. Confirm. Price. Publish.") }.font(.subheadline).foregroundStyle(PilotTheme.muted)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: textSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        metric("Active listings", "\(store.items.filter { $0.status == .active }.count)", "tag", opens: .active)
                        metric("Sold items", "\(store.items.filter { $0.status == .sold }.count)", "checkmark.circle", opens: .sold)
                        metric("Drafts", "\(drafts.count)", "pencil", opens: .drafts)
                        metric("Recorded sales", store.items.reduce(0) { $0 + ($1.soldPrice ?? 0) }.money, "dollarsign.circle", opens: .sold)
                    }
                    if BackupService.needsReminder(itemCount: store.items.count) {
                        Button { showSettings = true } label: {
                            PilotCard { Label("Back up your items", systemImage: "externaldrive.badge.icloud").font(.headline); Text("Your items and photos live only on this phone. Tap to save a backup.").font(.caption).foregroundStyle(PilotTheme.muted) }
                        }.buttonStyle(.plain).accessibilityIdentifier("backupReminder")
                    }
                    Text("Recent items").font(.title2.bold())
                    if store.items.isEmpty { PilotCard { Image(systemName: "camera.viewfinder").font(.largeTitle).foregroundStyle(PilotTheme.accent); Text("Your next sale starts with a photo.").font(.headline); Text("Add an item to get suggested prices and a listing you can share.").foregroundStyle(PilotTheme.muted) } }
                    ForEach(store.items.prefix(5)) { item in Button { selectedItem = item } label: { ItemCard(item: item) }.buttonStyle(.plain) }
                }.padding(22) }.background(PilotTheme.background).toolbar(.hidden, for: .navigationBar)
            }.tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            NavigationStack { InventoryView(store: store, filter: $inventoryFilter, onSelect: { selectedItem = $0 }) }.tabItem { Label("My Stuff", systemImage: "square.grid.2x2.fill") }.tag(Tab.stuff)
        }.sheet(isPresented: $showSettings) { SettingsView(store: store) }
            .sheet(item: $selectedItem) { item in WorkflowView(workflow: SellingWorkflow(item: item, store: store, services: AppServices.make())) }
            .alert("Storage issue", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    /// Brand on the left and Settings on the right. At the largest text sizes they stack so nothing breaks mid-word.
    private var header: some View {
        let brand = HStack { Image(systemName: "paperplane.fill").foregroundStyle(PilotTheme.accent).accessibilityHidden(true); Text("SELLPILOT").font(.headline).tracking(3).lineLimit(1).minimumScaleFactor(0.6) }
        let settings = Button { showSettings = true } label: {
            HStack(spacing: 8) {
                if AppMode.current == .developer { Text(ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "MVP • MOCK AI" : "MVP • AI ON").font(.caption.bold()).foregroundStyle(PilotTheme.muted).lineLimit(1).minimumScaleFactor(0.7) }
                Image(systemName: "gearshape").foregroundStyle(PilotTheme.muted)
            }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel("Settings")
        return Group {
            if textSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 4) { brand; settings } }
            else { HStack { brand; Spacer(); settings } }
        }
    }
    private var drafts: [SellItem] { store.items.filter { $0.status == .draft || $0.status == .ready } }
    /// Tapping a tile opens My Stuff on the matching list.
    private func metric(_ title: String, _ value: String, _ symbol: String, opens filter: InventoryFilter) -> some View {
        Button { inventoryFilter = filter; tab = .stuff } label: {
            PilotCard {
                HStack { Image(systemName: symbol).foregroundStyle(PilotTheme.accent); Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary).accessibilityHidden(true) }
                Text(value).font(.title.bold()); Text(title).font(.caption).foregroundStyle(PilotTheme.muted)
            }
        }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityHint("Shows \(filter.rawValue.lowercased()) items").accessibilityIdentifier("tile-\(filter.rawValue)-\(title)")
    }
}
struct InventoryView: View {
    var store: ItemStore; @Binding var filter: InventoryFilter; var onSelect: (SellItem) -> Void
    private var items: [SellItem] { store.items.filter { item in switch filter { case .active: item.status == .active; case .sold: item.status == .sold; case .archived: item.status == .archived; case .drafts: item.status == .draft || item.status == .ready } } }
    var body: some View { ScrollView { VStack(spacing: 16) {
        Picker("Status", selection: $filter) { ForEach(InventoryFilter.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
        if items.isEmpty { ContentUnavailableView("No \(filter.rawValue.lowercased()) yet", systemImage: "tag", description: Text("Your items will appear here as you sell.").foregroundStyle(PilotTheme.muted)) }
        ForEach(items) { item in Button { onSelect(item) } label: { ItemCard(item: item) }.buttonStyle(.plain) }
    }.padding(20) }.background(PilotTheme.background).navigationTitle("My Stuff") }
}
