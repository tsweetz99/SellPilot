import SwiftUI
import SwiftData
@main struct SellPilotApp: App {
    @State private var store: ItemStore?
    @State private var startupError: String?
    private var container: ModelContainer?
    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let configuration: ModelConfiguration
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let name = ProcessInfo.processInfo.environment["SELLPILOT_TEST_STORE"] {
                configuration = ModelConfiguration(url: support.appendingPathComponent("test-\(name).store"))
            } else { configuration = ModelConfiguration() }
            #else
            configuration = ModelConfiguration()
            #endif
            let container = try ModelContainer(for: StoredSellItem.self, configurations: configuration)
            self.container = container
            _store = State(initialValue: ItemStore(context: container.mainContext))
        } catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene { WindowGroup {
        if let store { HomeView(store: store).tint(PilotTheme.accent) }
        else { ContentUnavailableView("Saved data unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "Restart the app to try again. Your store has not been deleted.")) }
    } }
}
