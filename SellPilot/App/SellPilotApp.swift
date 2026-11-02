import SwiftUI
import SwiftData
@main struct SellPilotApp: App {
    @State private var store: ItemStore?
    @State private var startupError: String?
    #if DEBUG
    @State private var paywallDemo = ProcessInfo.processInfo.arguments.contains("--paywall-demo")
    #endif
    private var container: ModelContainer?
    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let configuration: ModelConfiguration
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let name = ProcessInfo.processInfo.environment["SELLPILOT_TEST_STORE"] {
                configuration = ModelConfiguration(url: support.appendingPathComponent("test-\(name).store"))
                PhotoStorage.shared = PhotoStorage(root: support.appendingPathComponent("test-photos-\(name)", isDirectory: true))
            } else { configuration = ModelConfiguration() }
            #else
            configuration = ModelConfiguration()
            #endif
            let container = try ModelContainer(for: StoredSellItem.self, configurations: configuration)
            self.container = container
            let store = ItemStore(context: container.mainContext)
            store.sweepOrphanedPhotos()
            _store = State(initialValue: store)
        } catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene { WindowGroup {
        if let store {
            HomeView(store: store).tint(PilotTheme.accent)
                // Learn eBay's current sign-in setup from the server, so nobody types it in.
                .task { if !ProcessInfo.processInfo.arguments.contains("--ui-testing") { await EbayDeployment.refresh() } }
                // Prices, purchases made elsewhere, and what the seller has left.
                .task { await PurchaseStore.shared.start() }
                #if DEBUG
                .task { ScreenshotDemo.seed(store) }
                .sheet(isPresented: $paywallDemo) { PaywallView(reason: "You've used your free analyses. Choose a plan or a pack to keep analyzing photos, or enter the details yourself.") }
                #endif
        }
        else { ContentUnavailableView("Saved data unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "Restart the app to try again. Your store has not been deleted.")) }
    } }
}
