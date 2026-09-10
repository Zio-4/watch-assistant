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
    private let audioController: AudioController
    private var reconnectAfterCurrent = false
    private var audioSettings: RealtimeSession.AudioSettings?
    private var captureTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var didSendAudio = false
    /// Simulator/debug only. Set by `-preview-ready`; skips the live Gateway session.
    private var isLocalPreview = false

    init(
        sessionClient: SessionClient = SessionClient(),
        gatewayClient: GatewayClient = GatewayClient(),
        credentialStore: CredentialStore = CredentialStore(),
        audioController: AudioController = AudioController()
    ) {
        self.sessionClient = sessionClient
        self.gatewayClient = gatewayClient
        self.credentialStore = credentialStore
        self.audioController = audioController
    }

    func connectIfNeeded() async {
        guard !isLocalPreview else { return }
        guard appSessionID == nil else { return }
        await connect()
    }

    #if DEBUG
    /// Simulator/debug only. Used with the `-preview-ready` launch argument.
    func preparePreviewReady() {
        isLocalPreview = true
        appSessionID = "preview"
        audioSettings = RealtimeSession.AudioSettings(
            inputFormat: "audio/pcm",
            outputFormat: "audio/pcm",
            sampleRate: 24_000,
            channels: 1
        )
        state = .ready
    }
    #endif

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
                audioSettings = session.audio
                listenToGateway()
                state = .ready
                DiagnosticLog.connection.info("Connected app session \(session.appSessionId, privacy: .public)")
            } catch {
                appSessionID = nil
                model = nil
                audioSettings = nil
                state = .failed(Self.message(for: error))
                DiagnosticLog.connection.error("Connection failed: \(error.localizedDescription, privacy: .public)")
            }

            actionInFlight = false
        } while reconnectAfterCurrent
    }

    func disconnect() async {
        await stopCaptureTasks()
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        audioSettings = nil
        guard !actionInFlight else { return }
        if case .failed = state { return }
        state = .connecting
    }

    func performPrimaryAction() async {
        switch state {
        case .failed:
            await retry()
        case .ready:
            await startTalk()
        case .recording:
            await finishTalk()
        case .connecting, .waiting, .playing:
            break
        }
    }

    private func startTalk() async {
        guard state == .ready, let audioSettings, !actionInFlight else { return }
        didSendAudio = false
        do {
            let chunks = try await audioController.startCapture(
                sampleRate: audioSettings.sampleRate,
                channels: audioSettings.channels
            )
            state = .recording
            captureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        // Simulator/debug: `-preview-ready` has no WebSocket, so skip sending.
                        if !self.isLocalPreview {
                            try await self.gatewayClient.sendAudioChunk(chunk)
                        }
                        self.didSendAudio = true
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await self.handleCaptureFailure(error)
                }
            }
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func finishTalk() async {
        guard state == .recording, !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }

        _ = await audioController.stopCapture()
        await captureTask?.value
        captureTask = nil

        do {
            guard didSendAudio else {
                await audioController.deleteTurnFile()
                state = .ready
                return
            }
            // Simulator/debug: no Gateway session to commit.
            if isLocalPreview {
                await audioController.deleteTurnFile()
                state = .waiting
                return
            }
            try await gatewayClient.commitTurn()
            state = .waiting
            DiagnosticLog.audio.info("Committed spoken turn")
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private func listenToGateway() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in await self.gatewayClient.events() {
                await self.handleGatewayEvent(event)
            }
        }
    }

    private func handleGatewayEvent(_ event: GatewayServerEvent) async {
        switch event {
        case .audioCommitted:
            DiagnosticLog.audio.info("Gateway accepted the turn")
            await audioController.deleteTurnFile()
        case .responseDone:
            if state == .waiting {
                state = .ready
            }
        case .error(let message):
            if state == .recording || state == .waiting {
                await stopCaptureTasks()
                state = .failed(message)
            }
        case .connectionClosed(let message):
            if state == .recording || state == .waiting || state == .ready {
                appSessionID = nil
                audioSettings = nil
                await stopCaptureTasks()
                state = .failed(message)
            }
        case .ignored:
            break
        }
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard state == .recording else { return }
        await stopCaptureTasks()
        state = .failed(Self.message(for: error))
    }

    private func stopCaptureTasks() async {
        captureTask?.cancel()
        eventTask?.cancel()
        captureTask = nil
        eventTask = nil
        _ = await audioController.stopCapture()
        await audioController.deleteTurnFile()
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
        if let audioError = error as? AudioControllerError {
            return audioError.localizedDescription
        }
        if let conversionError = error as? AudioConversionError {
            return conversionError.localizedDescription
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
