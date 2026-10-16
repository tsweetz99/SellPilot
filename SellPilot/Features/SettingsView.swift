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
                        do { try APIKeyStore.save(ebayApp, .ebayAppID); try APIKeyStore.save(ebayCert, .ebayCertID); ebayApp = ""; ebayCert = ""; hasEbay = true; message = "Saved. New items will use live eBay listings for pricing." }
                        catch { message = error.localizedDescription }
                    }.disabled(ebayApp.trimmingCharacters(in: .whitespaces).isEmpty || ebayCert.trimmingCharacters(in: .whitespaces).isEmpty)
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
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
