import Foundation
import Observation

@MainActor
@Observable
final class ConversationController {
    private(set) var state: ConversationState = .connecting
    private(set) var appSessionID: String?
    private(set) var model: String?
    private(set) var actionInFlight = false

    private let sessionClient: SessionClient
    private let gatewayClient: GatewayClient
    private let credentialStore: CredentialStore

    init(
        sessionClient: SessionClient = SessionClient(),
        gatewayClient: GatewayClient = GatewayClient(),
        credentialStore: CredentialStore = CredentialStore()
    ) {
        self.sessionClient = sessionClient
        self.gatewayClient = gatewayClient
        self.credentialStore = credentialStore
    }

    func connectIfNeeded() async {
        guard appSessionID == nil else { return }
        await connect()
    }

    func retry() async {
        guard !actionInFlight else { return }
        await disconnect()
        await connect()
    }

    func connect() async {
        guard !actionInFlight else { return }
        actionInFlight = true
        state = .connecting
        defer { actionInFlight = false }

        do {
            guard let endpoint = AppConfiguration.sessionServiceURL,
                  endpoint.scheme == "https" || endpoint.host == "localhost" else {
                throw ConversationError.invalidServiceURL
            }
            guard let credential = try credentialStore.read(), !credential.isEmpty else {
                throw ConversationError.missingCredential
            }

            let session = try await sessionClient.createSession(
                endpoint: endpoint,
                credential: credential
            )
            try await gatewayClient.connect(to: session)
            appSessionID = session.appSessionId
            model = session.model
            state = .ready
            DiagnosticLog.connection.info("Connected app session \(session.appSessionId, privacy: .public)")
        } catch {
            appSessionID = nil
            model = nil
            state = .failed(Self.message(for: error))
            DiagnosticLog.connection.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() async {
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        state = .connecting
    }

    func performPrimaryAction() async {
        guard !actionInFlight else { return }
        if case .failed = state {
            await retry()
        }
        // Talk, Done, and Reply become active when phase two adds audio capture.
    }

    private static func message(for error: Error) -> String {
        if let conversationError = error as? ConversationError {
            return conversationError.localizedDescription
        }
        if let sessionError = error as? SessionClientError {
            return sessionError.localizedDescription
        }
        return "Check the service URL, credential, and network, then retry."
    }
}

private enum ConversationError: LocalizedError {
    case invalidServiceURL
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidServiceURL:
            "Add the HTTPS Vercel session-service URL in Settings."
        case .missingCredential:
            "Add the personal app credential in Settings."
        }
    }
}
