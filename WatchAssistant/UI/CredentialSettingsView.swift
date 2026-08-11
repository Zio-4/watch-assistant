import SwiftUI

struct CredentialSettingsView: View {
    let controller: ConversationController

    @Environment(\.dismiss) private var dismiss
    @State private var serviceURL = UserDefaults.standard.string(
        forKey: AppConfiguration.sessionServiceURLKey
    ) ?? AppConfiguration.defaultSessionServiceURL
    @State private var credential = ""
    @State private var errorMessage: String?

    private let credentialStore = CredentialStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Session service") {
                    TextField("HTTPS URL", text: $serviceURL)
                        .textInputAutocapitalization(.never)
                }

                Section("Personal credential") {
                    SecureField("Credential", text: $credential)
                        .textInputAutocapitalization(.never)
                    Text("Leave blank to keep the saved value.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Button("Save and connect") {
                    save()
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func save() {
        let trimmedURL = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "https" else {
            errorMessage = "Enter a valid HTTPS URL."
            return
        }

        do {
            if !credential.isEmpty {
                try credentialStore.save(credential)
            }
            UserDefaults.standard.set(trimmedURL, forKey: AppConfiguration.sessionServiceURLKey)
            dismiss()
            Task { await controller.retry() }
        } catch {
            errorMessage = "The credential could not be saved."
        }
    }
}

