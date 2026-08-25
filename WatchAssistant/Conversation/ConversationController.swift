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
    private var reconnectAfterCurrent = false

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
        if actionInFlight {
            reconnectAfterCurrent = true
            return
        }
        await disconnect()
        await connect()
    }

    func connect(endpoint: URL? = nil, credential: String? = nil) async {
        if actionInFlight {
            reconnectAfterCurrent = true
            return
        }

        repeat {
            reconnectAfterCurrent = false
            actionInFlight = true
            state = .connecting

            do {
                let resolvedEndpoint = try resolvedEndpoint(endpoint)
                let resolvedCredential = try resolvedCredential(credential)
                let session = try await sessionClient.createSession(
                    endpoint: resolvedEndpoint,
                    credential: resolvedCredential
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

            actionInFlight = false
        } while reconnectAfterCurrent
    }

    func disconnect() async {
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        guard !actionInFlight else { return }
        if case .failed = state { return }
        state = .connecting
    }

    func performPrimaryAction() async {
        if case .failed = state {
            await retry()
        }
        // Talk, Done, and Reply become active when phase two adds audio capture.
    }

    private func resolvedEndpoint(_ endpoint: URL?) throws -> URL {
        let resolved = endpoint ?? AppConfiguration.sessionServiceURL
        guard let resolved, resolved.scheme == "https" || resolved.host == "localhost" else {
            throw ConversationError.invalidServiceURL
        }
        return resolved
    }

    private func resolvedCredential(_ credential: String?) throws -> String {
        if let credential, !credential.isEmpty {
            return credential
        }
        guard let stored = try credentialStore.read(), !stored.isEmpty else {
            throw ConversationError.missingCredential
        }
        return stored
    }

    private static func message(for error: Error) -> String {
        if let conversationError = error as? ConversationError {
            return conversationError.localizedDescription
        }
        if let sessionError = error as? SessionClientError {
            return sessionError.localizedDescription
        }
        if let gatewayError = error as? GatewayClientError {
            return gatewayError.localizedDescription
        }
        return error.localizedDescription
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
