import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var hasKey = APIKeyStore.load() != nil
    @State private var message: String?

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
                if let message { Section { Text(message).font(.footnote) } }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
