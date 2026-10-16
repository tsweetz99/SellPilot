import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = APIKeyStore.load() != nil
    @State private var message: String?
    @State private var ebayApp = ""
    @State private var ebayCert = ""
    @State private var hasEbay = EbayCredentials.load() != nil

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
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
