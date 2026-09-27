import Foundation
import Observation

@MainActor
@Observable
final class ConversationController {
    private(set) var state: ConversationState = .connecting
    private(set) var appSessionID: String?
    private(set) var model: String?
    private(set) var actionInFlight = false
    private(set) var hasLastResponse = false
    private(set) var transcripts: [ConversationTranscript] = []

    private let sessionClient: SessionClient
    private let gatewayClient: GatewayClient
    private let credentialStore: CredentialStore
    private let audioController: AudioController
    private var reconnectAfterCurrent = false
    private var audioSettings: RealtimeSession.AudioSettings?
    private var captureTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var playbackWatchTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var renewalInFlight = false
    private var renewalStopped = false
    private var responseOpen = false
    private var isStartingReply = false
    private var ignoreGatewayErrorUntil: Date?
    private var closeRenewalAttempts = 0
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
        if case .failed = state { return }
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
            renewalStopped = false
            renewalTask?.cancel()
            renewalTask = nil
            transcripts = []
            responseOpen = false
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
                scheduleTokenRenewal(at: Self.expirationDate(from: session.expiresAt))
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
        renewalStopped = true
        renewalTask?.cancel()
        renewalTask = nil
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: false)
        hasLastResponse = false
        transcripts = []
        responseOpen = false
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
        case .playing:
            await reply()
        case .connecting, .waiting:
            break
        }
    }

    func replay() async {
        guard state == .ready || state == .playing, !actionInFlight else { return }
        if !hasLastResponse {
            guard await audioController.hasLastResponse else { return }
        }
        actionInFlight = true
        do {
            try await audioController.replayLastResponse()
            hasLastResponse = true
            state = .playing
            actionInFlight = false
            watchPlaybackUntilFinished()
        } catch {
            actionInFlight = false
            state = .failed(Self.message(for: error))
        }
    }

    func endSession() async {
        guard state.showsEndAction, !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        renewalStopped = true
        renewalTask?.cancel()
        renewalTask = nil
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: false)
        hasLastResponse = false
        transcripts = []
        responseOpen = false
        await stopCaptureTasks()
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        audioSettings = nil
        state = .failed(ConversationState.sessionEndedMessage)
    }

    private func startTalk() async {
        guard state == .ready || state == .playing, let audioSettings, !actionInFlight else { return }
        actionInFlight = true
        isStartingReply = true
        defer {
            isStartingReply = false
            actionInFlight = false
        }
        let shouldCancelResponse = state == .playing && responseOpen && !isLocalPreview
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: true)
        if !isLocalPreview {
            ignoreGatewayErrorUntil = Date().addingTimeInterval(2)
            if shouldCancelResponse {
                await gatewayClient.cancelActiveResponse()
                responseOpen = false
            }
            await gatewayClient.clearInputBuffer()
        }
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

    private func reply() async {
        guard state == .playing, !actionInFlight else { return }
        await startTalk()
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
                playPreviewResponse(audioSettings)
                return
            }
            try await gatewayClient.commitTurn()
            responseOpen = true
            closeRenewalAttempts = 0
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
        case .audioReceived(let data, _):
            guard !isStartingReply else { return }
            guard state == .waiting || state == .playing, let audioSettings else { return }
            do {
                try await audioController.enqueuePlayback(
                    data,
                    sampleRate: audioSettings.sampleRate,
                    channels: audioSettings.channels
                )
                hasLastResponse = true
                if state == .waiting {
                    state = .playing
                }
            } catch {
                state = .failed(Self.message(for: error))
            }
        case .inputTranscript(let itemID, let text):
            storeUserTranscript(itemID: itemID, text: text)
        case .assistantTranscriptDelta(let itemID, let delta):
            storeAssistantDelta(itemID: itemID, delta: delta)
        case .assistantTranscriptDone(let itemID, let text):
            storeAssistantDone(itemID: itemID, text: text)
        case .responseDone:
            responseOpen = false
            if isStartingReply { return }
            do {
                try await audioController.markPlaybackInputFinished()
            } catch {
                state = .failed(Self.message(for: error))
                return
            }
            if state == .waiting {
                await audioController.deleteTurnFile()
                state = .ready
            } else if state == .playing {
                watchPlaybackUntilFinished()
            }
        case .error(let message):
            if let until = ignoreGatewayErrorUntil, until > Date() {
                DiagnosticLog.connection.error(
                    "Ignored model error while starting a reply: \(message, privacy: .public)"
                )
                return
            }
            if state == .recording || state == .waiting || state == .playing {
                responseOpen = false
                await interruptAudio()
                state = .failed(message)
            }
        case .connectionClosed(let message):
            if state == .ready,
               !renewalInFlight,
               !isLocalPreview,
               appSessionID != nil,
               closeRenewalAttempts < 2 {
                closeRenewalAttempts += 1
                Task { await self.renewSessionToken() }
                return
            }
            if state == .recording || state == .waiting || state == .playing || state == .ready {
                responseOpen = false
                appSessionID = nil
                audioSettings = nil
                await interruptAudio()
                state = .failed(message)
            }
        case .ignored:
            break
        }
    }

    private func playPreviewResponse(_ audioSettings: RealtimeSession.AudioSettings?) {
        guard let audioSettings else {
            state = .ready
            return
        }
        playbackWatchTask?.cancel()
        playbackWatchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, self.state == .waiting else { return }
            do {
                let turn = self.transcripts.filter { $0.role == .user }.count + 1
                self.transcripts.append(
                    ConversationTranscript(
                        id: "preview-user-\(turn)",
                        role: .user,
                        text: "Preview question \(turn)"
                    )
                )
                self.transcripts.append(
                    ConversationTranscript(
                        id: "preview-assistant-\(turn)",
                        role: .assistant,
                        text: "Preview answer \(turn)"
                    )
                )
                self.state = .playing
                let tone = AudioFormatConverter.previewTonePCM16(
                    sampleRate: audioSettings.sampleRate,
                    channels: max(audioSettings.channels, 1)
                )
                try await self.audioController.enqueuePlayback(
                    tone,
                    sampleRate: audioSettings.sampleRate,
                    channels: max(audioSettings.channels, 1)
                )
                self.hasLastResponse = true
                try await self.audioController.markPlaybackInputFinished()
                await self.audioController.waitUntilPlaybackFinished()
                guard !Task.isCancelled, self.state == .playing else { return }
                await self.audioController.deleteTurnFile()
                self.state = .ready
            } catch {
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    private func watchPlaybackUntilFinished() {
        playbackWatchTask?.cancel()
        playbackWatchTask = Task { [weak self] in
            guard let self else { return }
            await self.audioController.waitUntilPlaybackFinished()
            guard !Task.isCancelled, self.state == .playing else { return }
            await self.audioController.deleteTurnFile()
            self.closeRenewalAttempts = 0
            self.state = .ready
        }
    }

    private func interruptAudio() async {
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: true)
        await stopCaptureTasks()
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard state == .recording else { return }
        await interruptAudio()
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

    private func scheduleTokenRenewal(at expiresAt: Date) {
        let remaining = expiresAt.timeIntervalSinceNow
        let delay: TimeInterval = remaining > 20 ? remaining - 15 : max(remaining * 0.5, 10)
        renewalTask?.cancel()
        renewalTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            await self?.renewSessionToken()
        }
    }

    private func renewSessionToken() async {
        guard !renewalStopped, !isLocalPreview, let currentSessionID = appSessionID else { return }
        if renewalInFlight { return }
        if case .failed = state { return }

        renewalInFlight = true
        defer { renewalInFlight = false }

        while state != .ready || actionInFlight {
            if Task.isCancelled || renewalStopped || appSessionID == nil { return }
            if case .failed = state { return }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || renewalStopped { return }
        }

        actionInFlight = true
        defer {
            actionInFlight = false
            if reconnectAfterCurrent {
                reconnectAfterCurrent = false
                Task { await self.connect() }
            }
        }

        do {
            let endpoint = try resolvedEndpoint(nil)
            let credential = try resolvedCredential(nil)
            let session = try await sessionClient.createSession(
                endpoint: endpoint,
                credential: credential,
                appSessionId: currentSessionID
            )
            guard !Task.isCancelled, !renewalStopped, appSessionID == currentSessionID, state == .ready else {
                return
            }
            try await gatewayClient.renewConnection(to: session, transcripts: transcripts)
            guard !Task.isCancelled, !renewalStopped, appSessionID == currentSessionID, state == .ready else {
                await gatewayClient.disconnect()
                return
            }
            model = session.model
            audioSettings = session.audio
            // Drop the finished sleep task before arming the next one so this
            // call does not cancel itself.
            renewalTask = nil
            scheduleTokenRenewal(at: Self.expirationDate(from: session.expiresAt))
            DiagnosticLog.connection.info("Renewed the model session token")
        } catch {
            DiagnosticLog.connection.error(
                "Token renewal failed: \(error.localizedDescription, privacy: .public)"
            )
            guard !renewalStopped, appSessionID == currentSessionID else { return }
            if await gatewayClient.isConnected {
                renewalTask = nil
                scheduleTokenRenewal(at: Date().addingTimeInterval(20))
            } else if state == .ready {
                responseOpen = false
                appSessionID = nil
                audioSettings = nil
                state = .failed(Self.message(for: error))
            }
        }
    }

    private var canStoreTranscript: Bool {
        switch state {
        case .ready, .recording, .waiting, .playing:
            true
        case .connecting, .failed:
            false
        }
    }

    private func storeUserTranscript(itemID: String, text: String) {
        guard canStoreTranscript else { return }
        upsertTranscript(id: "user-\(itemID)", role: .user, text: text, append: false)
        DiagnosticLog.transcript.info("Stored user transcript")
    }

    private func storeAssistantDelta(itemID: String, delta: String) {
        guard canStoreTranscript else { return }
        upsertTranscript(id: "assistant-\(itemID)", role: .assistant, text: delta, append: true)
    }

    private func storeAssistantDone(itemID: String, text: String) {
        guard canStoreTranscript else { return }
        let id = "assistant-\(itemID)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if transcripts.contains(where: { $0.id == id }) {
                DiagnosticLog.transcript.info("Stored assistant transcript")
            }
            return
        }
        upsertTranscript(id: id, role: .assistant, text: text, append: false)
        DiagnosticLog.transcript.info("Stored assistant transcript")
    }

    private func upsertTranscript(
        id: String,
        role: ConversationTranscript.Role,
        text: String,
        append: Bool
    ) {
        if let index = transcripts.firstIndex(where: { $0.id == id }) {
            if append {
                transcripts[index].text += text
            } else {
                transcripts[index].text = text
            }
        } else {
            transcripts.append(ConversationTranscript(id: id, role: role, text: text))
        }
    }

    private static func expirationDate(from expiresAt: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt) ?? Date().addingTimeInterval(60)
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
