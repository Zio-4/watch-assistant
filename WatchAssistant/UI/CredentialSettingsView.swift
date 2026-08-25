import SwiftUI

struct CredentialSettingsView: View {
    let controller: ConversationController

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?
    @State private var serviceURL = UserDefaults.standard.string(
        forKey: AppConfiguration.sessionServiceURLKey
    ) ?? AppConfiguration.defaultSessionServiceURL
    @State private var credential = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let credentialStore = CredentialStore()

    private enum Field: Hashable {
        case url
        case credential
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption2)
                }

                Section("Session service") {
                    TextField("HTTPS URL", text: $serviceURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                }

                Section("Personal credential") {
                    TextField("Credential", text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .credential)
                    Text("Leave blank to keep the saved value.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("Save and connect") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    @MainActor
    private func save() async {
        focusedField = nil
        isSaving = true
        defer { isSaving = false }

        let trimmedURL = serviceURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard let url = URL(string: trimmedURL), url.scheme == "https" else {
            errorMessage = "Enter a valid HTTPS URL."
            return
        }

        let trimmedCredential = credential
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")

        do {
            let storedCredential = try credentialStore.read()
            let resolvedCredential = trimmedCredential.isEmpty ? storedCredential : trimmedCredential
            guard let resolvedCredential, !resolvedCredential.isEmpty else {
                errorMessage = "Enter the personal app credential."
                return
            }
            if !trimmedCredential.isEmpty {
                try credentialStore.save(resolvedCredential)
            }
            UserDefaults.standard.set(trimmedURL, forKey: AppConfiguration.sessionServiceURLKey)
            dismiss()
            await controller.connect(endpoint: url, credential: resolvedCredential)
        } catch {
            errorMessage = "The credential could not be saved."
        }
    }
}
