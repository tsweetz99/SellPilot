import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = APIKeyStore.load() != nil
    @State private var message: String?
    @State private var ebayApp = ""
    @State private var ebayCert = ""
    @State private var hasEbay = EbayCredentials.load() != nil
    @State private var sbxApp = ""
    @State private var sbxCert = ""
    @State private var sbxToken = ""
    @State private var hasSandbox = APIKeyStore.load(.ebaySandboxUserToken) != nil
    @State private var sbxRuName = ""
    @State private var proxyURL = ""
    @State private var connection = EbayConnections.make(.sandbox)
    @State private var liveRuName = ""
    @State private var zip = LiveSettings.shipFromZip
    @State private var liveOn = LiveSettings.enabled
    @State private var liveConnection = EbayConnections.make(.production)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Anthropic API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") {
                        do { try APIKeyStore.save(key); key = ""; hasKey = true; message = "Saved. New items will use AI identification." }
                        catch { message = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey { Button("Remove key", role: .destructive) { APIKeyStore.delete(); hasKey = APIKeyStore.load() != nil; message = "Removed. Demo mode is on." } }
                } header: { Text("AI identification") } footer: {
                    Text(hasKey ? "AI identification is on. Photos you analyze are sent to Anthropic's Claude service." : "No key set: demo mode always returns a sample tool. Prototype setting. The key stays in this device's Keychain; a public release should use your own server instead.")
                }
                Section {
                    SecureField("eBay App ID", text: $ebayApp).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("eBay Cert ID", text: $ebayCert).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save eBay keys") {
                        do {
                            if let problem = EbayKeyCheck.problem(appID: ebayApp, production: true) { message = problem; return }
                            if !ebayApp.isEmpty { try APIKeyStore.save(ebayApp, .ebayAppID) }
                            if !ebayCert.isEmpty { try APIKeyStore.save(ebayCert, .ebayCertID) }
                            ebayApp = ""; ebayCert = ""; hasEbay = EbayCredentials.load() != nil; liveConnection = EbayConnections.make(.production)
                            message = "Saved. New items will use live eBay listings for pricing."
                        } catch { message = error.localizedDescription }
                    }.disabled(ebayApp.trimmingCharacters(in: .whitespaces).isEmpty && ebayCert.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasEbay { Button("Remove eBay keys", role: .destructive) { APIKeyStore.delete(.ebayAppID); APIKeyStore.delete(.ebayCertID); hasEbay = EbayCredentials.load() != nil; message = "Removed. Pricing uses demo data." } }
                } header: { Text("eBay market data") } footer: {
                    Text(hasEbay ? "Pricing uses similar active eBay listings. These are asking prices, not sold prices." : "No keys set: pricing uses demo data. Use your eBay Production App ID and Cert ID.")
                }
                Section {
                    SecureField("Sandbox App ID", text: $sbxApp).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Sandbox Cert ID", text: $sbxCert).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Sandbox user token", text: $sbxToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save sandbox details") {
                        do {
                            if let problem = EbayKeyCheck.problem(appID: sbxApp, production: false) { message = problem; return }
                            if !sbxApp.isEmpty { try APIKeyStore.save(sbxApp, .ebaySandboxAppID) }
                            if !sbxCert.isEmpty { try APIKeyStore.save(sbxCert, .ebaySandboxCertID) }
                            if !sbxToken.isEmpty { try APIKeyStore.save(sbxToken, .ebaySandboxUserToken) }
                            sbxApp = ""; sbxCert = ""; sbxToken = ""; hasSandbox = APIKeyStore.load(.ebaySandboxUserToken) != nil
                            message = "Saved. Ready listings can be published to the eBay Sandbox."
                        } catch { message = error.localizedDescription }
                    }.disabled(sbxApp.isEmpty && sbxCert.isEmpty && sbxToken.isEmpty)
                    if hasSandbox { Button("Remove sandbox details", role: .destructive) { [APIKeyStore.Account.ebaySandboxAppID, .ebaySandboxCertID, .ebaySandboxUserToken].forEach { APIKeyStore.delete($0) }; hasSandbox = APIKeyStore.load(.ebaySandboxUserToken) != nil; message = "Removed." } }
                } header: { Text("eBay Sandbox (testing)") } footer: {
                    Text("For test listings only. Nothing is posted to real eBay. The user token expires after about two hours; paste a fresh one from the eBay developer portal when it does.")
                }
                Section {
                    SecureField("eBay redirect name (RuName)", text: $sbxRuName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Token server URL (optional)", text: $proxyURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Save sign-in settings") {
                        do {
                            if !sbxRuName.isEmpty { try APIKeyStore.save(sbxRuName, .ebaySandboxRuName) }
                            if !proxyURL.isEmpty { try APIKeyStore.save(proxyURL, .ebayAuthProxy) }
                            sbxRuName = ""; proxyURL = ""; connection = EbayConnections.make(.sandbox)
                            message = connection == nil ? "Saved. Sign-in also needs the Sandbox App ID and either the Cert ID or a token server URL." : "Saved. You can connect now."
                        } catch { message = error.localizedDescription }
                    }.disabled(sbxRuName.isEmpty && proxyURL.isEmpty)
                    if let connection { EbayConnectRow(connection: connection) }
                } header: { Text("eBay Sandbox sign-in") } footer: {
                    Text("Sign in with a sandbox test seller instead of pasting a token. SellPilot never sees your eBay password. With a token server, eBay sign-in and app tokens go through it and the Cert ID is not needed on this device. Without one, the Cert ID is used directly from this device, which is fine for testing only.")
                }
                Section {
                    SecureField("Production redirect name (RuName)", text: $liveRuName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Ship-from ZIP code", text: $zip).keyboardType(.numberPad)
                    Button("Save live settings") {
                        do {
                            if !liveRuName.isEmpty { try APIKeyStore.save(liveRuName, .ebayRuName) }
                            guard zip.isEmpty || LiveSettings.isValidZip(zip) else { message = "Enter a 5-digit ZIP code."; return }
                            LiveSettings.shipFromZip = zip
                            liveRuName = ""; liveConnection = EbayConnections.make(.production); message = "Saved."
                        } catch { message = error.localizedDescription }
                    }.disabled(liveRuName.isEmpty && zip == LiveSettings.shipFromZip)
                    if let liveConnection { EbayConnectRow(connection: liveConnection) }
                    Toggle("Publish to real eBay", isOn: Binding(get: { liveOn }, set: { liveOn = $0; LiveSettings.enabled = $0 }))
                        .disabled(!liveOn && !(LiveSettings.isValidZip(LiveSettings.shipFromZip) && liveConnection?.status == .connected))
                } header: { Text("Real eBay (live listings)") } footer: {
                    Text("Off by default. When on, listings you publish go to REAL eBay, where real buyers can purchase them and eBay may charge fees. It needs your Production App ID (in eBay market data above), a Production sign-in, and the ZIP code you ship from. Turn it off to go back to the sandbox.")
                }
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct EbayConnectRow: View {
    var connection: EbayConnection
    var body: some View {
        switch connection.status {
        case .connected:
            Label(connection.configuration.environment == .sandbox ? "Connected to eBay Sandbox" : "Connected to eBay", systemImage: "checkmark.seal.fill").foregroundStyle(PilotTheme.accent)
            Button("Disconnect", role: .destructive) { connection.disconnect() }
        case .connecting:
            HStack { ProgressView(); Text("Waiting for eBay…") }
        case .disconnected, .failed:
            if case .failed(let reason) = connection.status { Text(reason).font(.footnote).foregroundStyle(.red) }
            Button(connection.configuration.environment == .sandbox ? "Connect eBay Sandbox account" : "Connect eBay account") { Task { await connection.connect() } }.accessibilityIdentifier(connection.configuration.environment == .sandbox ? "connectEbay" : "connectEbayLive")
        }
    }
}
