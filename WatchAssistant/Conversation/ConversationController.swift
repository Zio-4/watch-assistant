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
    private(set) var isReconnecting = false
    private(set) var hapticSignal: HapticSignal?

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
    private var recoveryTask: Task<Void, Never>?
    private var audioProblemTask: Task<Void, Never>?
    private var renewalInFlight = false
    private var renewalStopped = false
    private var responseOpen = false
    private var isStartingReply = false
    private var didSendAudio = false
    private var turnAccepted = false
    private var uploadInterrupted = false
    private var committedTranscriptCount = 0
    private var automaticRecoveryLeft = 1
    private var sessionGeneration = 0
    private var commitDate: Date?
    private var loggedFirstAudioLatency = false
    private var failureAfterPlayback: String?
    private var hapticToken = 0
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
        startAudioProblemListener()
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
        transition(to: .ready)
    }
    #endif

    func retry() async {
        if actionInFlight {
            reconnectAfterCurrent = true
            return
        }
        repeat {
            reconnectAfterCurrent = false
            await performRetry()
        } while reconnectAfterCurrent
    }

    func connect(endpoint: URL? = nil, credential: String? = nil) async {
        if actionInFlight {
            reconnectAfterCurrent = true
            return
        }

        repeat {
            reconnectAfterCurrent = false
            sessionGeneration += 1
            let generation = sessionGeneration
            recoveryTask?.cancel()
            recoveryTask = nil
            actionInFlight = true
            renewalStopped = false
            renewalTask?.cancel()
            renewalTask = nil
            isReconnecting = false
            transcripts = []
            committedTranscriptCount = 0
            responseOpen = false
            turnAccepted = false
            uploadInterrupted = false
            commitDate = nil
            failureAfterPlayback = nil
            transition(to: .connecting)

            do {
                let resolvedEndpoint = try resolvedEndpoint(endpoint)
                let resolvedCredential = try resolvedCredential(credential)
                let session = try await sessionClient.createSession(
                    endpoint: resolvedEndpoint,
                    credential: resolvedCredential
                )
                guard generation == sessionGeneration else {
                    actionInFlight = false
                    return
                }
                try await gatewayClient.connect(to: session)
                guard generation == sessionGeneration else {
                    actionInFlight = false
                    return
                }
                appSessionID = session.appSessionId
                model = session.model
                audioSettings = session.audio
                listenToGateway()
                guard await gatewayClient.isConnected else {
                    if recoveryTask == nil {
                        await presentConnectionLost()
                    }
                    actionInFlight = false
                    continue
                }
                guard generation == sessionGeneration else {
                    actionInFlight = false
                    return
                }
                transition(to: .ready)
                scheduleTokenRenewal(at: Self.expirationDate(from: session.expiresAt))
                DiagnosticLog.connection.info(
                    "Connected app session \(session.appSessionId, privacy: .public)"
                )
            } catch {
                guard generation == sessionGeneration else {
                    actionInFlight = false
                    return
                }
                appSessionID = nil
                model = nil
                audioSettings = nil
                transition(to: .failed(Self.message(for: error)))
                DiagnosticLog.connection.error(
                    "Connection failed: \(error.localizedDescription, privacy: .public)"
                )
            }

            actionInFlight = false
        } while reconnectAfterCurrent
    }

    func disconnect() async {
        let label = sessionLabel
        sessionGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        renewalStopped = true
        renewalTask?.cancel()
        renewalTask = nil
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        failureAfterPlayback = nil
        isReconnecting = false
        await audioController.stopPlayback(keepLastResponse: false)
        hasLastResponse = false
        transcripts = []
        committedTranscriptCount = 0
        responseOpen = false
        turnAccepted = false
        uploadInterrupted = false
        eventTask?.cancel()
        eventTask = nil
        await stopCaptureTasks(deleteTurnFile: true)
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        audioSettings = nil
        DiagnosticLog.connection.info("Disconnected app session \(label, privacy: .public)")
        guard !actionInFlight else { return }
        if case .failed = state { return }
        transition(to: .connecting)
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
        guard state == .ready || state == .playing, !actionInFlight, !isReconnecting else { return }
        if !hasLastResponse {
            guard await audioController.hasLastResponse else { return }
        }
        actionInFlight = true
        do {
            try await audioController.replayLastResponse()
            hasLastResponse = true
            transition(to: .playing)
            actionInFlight = false
            watchPlaybackUntilFinished()
        } catch {
            actionInFlight = false
            DiagnosticLog.audio.error(
                "Replay failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            transition(to: .failed(Self.message(for: error)))
        }
    }

    func endSession() async {
        guard state.showsEndAction, !actionInFlight, !isReconnecting else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        let label = sessionLabel
        sessionGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
        renewalStopped = true
        renewalTask?.cancel()
        renewalTask = nil
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        failureAfterPlayback = nil
        isReconnecting = false
        await audioController.stopPlayback(keepLastResponse: false)
        hasLastResponse = false
        transcripts = []
        committedTranscriptCount = 0
        responseOpen = false
        turnAccepted = false
        uploadInterrupted = false
        eventTask?.cancel()
        eventTask = nil
        await stopCaptureTasks(deleteTurnFile: true)
        await gatewayClient.disconnect()
        appSessionID = nil
        model = nil
        audioSettings = nil
        DiagnosticLog.connection.info("Ended app session \(label, privacy: .public)")
        transition(to: .failed(ConversationState.sessionEndedMessage))
    }

    private func performRetry() async {
        automaticRecoveryLeft = 1
        if case .failed(let message) = state {
            if message == ConversationState.sessionEndedMessage {
                await disconnect()
                await connect()
                return
            }
            if message == ConversationState.microphoneDeniedMessage
                || message == ConversationState.audioRouteMessage {
                await retryAudioAccess()
                return
            }
        }
        if isLocalPreview {
            transition(to: .ready)
            return
        }
        let hasPendingTurn = await audioController.hasPendingTurnFile()
        let resume = !turnAccepted && hasPendingTurn
        if resume {
            uploadInterrupted = true
        }
        if appSessionID != nil || resume {
            scheduleRecovery(resumeTurn: resume, userInitiated: true)
            await recoveryTask?.value
            if case .failed = state { return }
            if state == .connecting || isReconnecting {
                await presentConnectionLost()
            }
            return
        }
        await disconnect()
        await connect()
    }

    private func retryAudioAccess() async {
        let granted = await audioController.resolveMicrophoneAccess()
        guard granted else {
            DiagnosticLog.audio.error(
                "Microphone permission denied session=\(self.sessionLabel, privacy: .public)"
            )
            transition(to: .failed(ConversationState.microphoneDeniedMessage))
            return
        }
        do {
            try await audioController.prepareAudioRoute()
        } catch {
            DiagnosticLog.audio.error(
                "Audio route unavailable session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            transition(to: .failed(ConversationState.audioRouteMessage))
            return
        }
        let gatewayConnected = await gatewayClient.isConnected
        if isLocalPreview || gatewayConnected {
            transition(to: .ready)
            return
        }
        if appSessionID != nil {
            scheduleRecovery(resumeTurn: false, userInitiated: true)
            await recoveryTask?.value
            return
        }
        await connect()
    }

    private func startTalk() async {
        guard state == .ready || state == .playing, let audioSettings, !actionInFlight, !isReconnecting else {
            return
        }
        actionInFlight = true
        isStartingReply = true
        defer {
            isStartingReply = false
            actionInFlight = false
        }
        let shouldCancelResponse = state == .playing && responseOpen && !isLocalPreview
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        failureAfterPlayback = nil
        await audioController.stopPlayback(keepLastResponse: true)
        if !isLocalPreview {
            if shouldCancelResponse {
                await gatewayClient.cancelActiveResponse()
                responseOpen = false
            }
            await gatewayClient.clearInputBuffer()
        }
        didSendAudio = false
        uploadInterrupted = false
        turnAccepted = false
        committedTranscriptCount = transcripts.count
        if case .failed = state { return }
        do {
            let chunks = try await audioController.startCapture(
                sampleRate: audioSettings.sampleRate,
                channels: audioSettings.channels
            )
            if case .failed = state {
                _ = await audioController.stopCapture()
                return
            }
            transition(to: .recording)
            DiagnosticLog.audio.info("Listening session=\(self.sessionLabel, privacy: .public)")
            captureTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        // Simulator/debug: `-preview-ready` has no WebSocket, so skip sending.
                        if self.isLocalPreview || self.uploadInterrupted {
                            self.didSendAudio = true
                            continue
                        }
                        do {
                            try await self.gatewayClient.sendAudioChunk(chunk)
                            self.didSendAudio = true
                        } catch {
                            guard Self.isRecoverableNetwork(error) else { throw error }
                            if !self.uploadInterrupted {
                                DiagnosticLog.audio.error(
                                    "Upload interrupted session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                )
                            }
                            self.uploadInterrupted = true
                            self.didSendAudio = true
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await self.handleCaptureFailure(error)
                }
            }
        } catch {
            DiagnosticLog.audio.error(
                "Capture failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            transition(to: .failed(Self.message(for: error)))
        }
    }

    private func reply() async {
        guard state == .playing, !actionInFlight, !isReconnecting else { return }
        await startTalk()
    }

    private func finishTalk() async {
        guard state == .recording, !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }

        _ = await audioController.stopCapture()
        await captureTask?.value
        captureTask = nil
        guard state == .recording else { return }

        let hasPendingTurn = await audioController.hasPendingTurnFile()
        let hasAudio = didSendAudio || hasPendingTurn
        guard hasAudio else {
            await audioController.deleteTurnFile()
            transition(to: .ready)
            return
        }
        // Simulator/debug: no Gateway session to commit.
        if isLocalPreview {
            await audioController.deleteTurnFile()
            transition(to: .waiting)
            playPreviewResponse(audioSettings)
            return
        }

        let gatewayConnected = await gatewayClient.isConnected
        let needsResend = uploadInterrupted || !gatewayConnected
        do {
            if needsResend {
                uploadInterrupted = true
                scheduleRecovery(resumeTurn: true, userInitiated: true)
                await recoveryTask?.value
                if case .failed = state { return }
                if state != .waiting && state != .playing && state != .ready {
                    await presentConnectionLost()
                }
            } else {
                try await commitLiveTurn()
            }
        } catch {
            DiagnosticLog.audio.error(
                "Turn upload failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            guard Self.isRecoverableNetwork(error) else {
                transition(to: .failed(Self.message(for: error)))
                return
            }
            uploadInterrupted = true
            scheduleRecovery(resumeTurn: true, userInitiated: true)
            await recoveryTask?.value
            if case .failed = state { return }
            if state != .waiting && state != .playing && state != .ready {
                await presentConnectionLost()
            }
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
            guard state == .waiting || state == .playing else { return }
            turnAccepted = true
            uploadInterrupted = false
            committedTranscriptCount = transcripts.count
            DiagnosticLog.audio.info(
                "Gateway accepted the turn session=\(self.sessionLabel, privacy: .public)"
            )
            await audioController.deleteTurnFile()
        case .audioReceived(let data, _):
            logFirstAudioLatency()
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
                    transition(to: .playing)
                }
            } catch {
                DiagnosticLog.audio.error(
                    "Playback failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                transition(to: .failed(Self.message(for: error)))
            }
        case .inputTranscript(let itemID, let text):
            storeUserTranscript(itemID: itemID, text: text)
        case .assistantTranscriptDelta(let itemID, let delta):
            storeAssistantDelta(itemID: itemID, delta: delta)
        case .assistantTranscriptDone(let itemID, let text):
            storeAssistantDone(itemID: itemID, text: text)
        case .responseDone:
            logResponseLatency()
            responseOpen = false
            if isStartingReply { return }
            if state == .waiting || state == .playing {
                turnAccepted = true
                uploadInterrupted = false
                committedTranscriptCount = transcripts.count
            }
            do {
                try await audioController.markPlaybackInputFinished()
            } catch {
                DiagnosticLog.audio.error(
                    "Playback failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                transition(to: .failed(Self.message(for: error)))
                return
            }
            if state == .waiting {
                await audioController.deleteTurnFile()
                transition(to: .ready)
            } else if state == .playing {
                watchPlaybackUntilFinished()
            }
        case .error(let message):
            DiagnosticLog.connection.error(
                "Model error session=\(self.sessionLabel, privacy: .public): \(message, privacy: .public)"
            )
            guard state == .recording || state == .waiting || state == .playing else { return }
            responseOpen = false
            await interruptAudio()
            transition(to: .failed(message))
        case .connectionClosed(let message):
            DiagnosticLog.connection.error(
                "Connection lost session=\(self.sessionLabel, privacy: .public): \(message, privacy: .public)"
            )
            guard state == .recording || state == .waiting || state == .playing || state == .ready else {
                return
            }
            responseOpen = false
            switch state {
            case .recording:
                uploadInterrupted = true
            case .waiting:
                if !turnAccepted {
                    uploadInterrupted = true
                }
                scheduleRecovery(resumeTurn: !turnAccepted, userInitiated: false)
            case .ready, .playing:
                scheduleRecovery(resumeTurn: false, userInitiated: false)
            case .connecting, .failed:
                break
            }
        case .ignored:
            break
        }
    }

    private func scheduleRecovery(resumeTurn: Bool, userInitiated: Bool) {
        if recoveryTask != nil { return }
        if !userInitiated {
            guard automaticRecoveryLeft > 0 else {
                Task { [weak self] in
                    await self?.presentConnectionLost()
                }
                return
            }
            automaticRecoveryLeft -= 1
        } else {
            automaticRecoveryLeft = 1
        }

        let preservePlayback = state == .playing
        let generation = sessionGeneration
        let ownsFlag = !actionInFlight
        if ownsFlag {
            actionInFlight = true
        }
        if !preservePlayback {
            isReconnecting = true
            transition(to: .connecting)
        }
        DiagnosticLog.connection.info(
            "Reconnecting app session \(self.sessionLabel, privacy: .public)"
        )
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if ownsFlag {
                    self.actionInFlight = false
                }
                self.recoveryTask = nil
            }
            guard generation == self.sessionGeneration else { return }
            do {
                try await self.recoverConnection(
                    resumeTurn: resumeTurn,
                    preservePlayback: preservePlayback
                )
            } catch {
                guard !Task.isCancelled, generation == self.sessionGeneration else { return }
                if error is CancellationError { return }
                if case .failed = self.state { return }
                DiagnosticLog.connection.error(
                    "Reconnect failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                let message = Self.isRecoverableNetwork(error)
                    ? ConversationState.connectionLostMessage
                    : Self.message(for: error)
                if self.state == .playing {
                    self.isReconnecting = false
                    self.failureAfterPlayback = message
                    return
                }
                await self.failVisibleSession(message, endSession: !Self.isRecoverableNetwork(error))
            }
        }
    }

    private func recoverConnection(resumeTurn: Bool, preservePlayback: Bool) async throws {
        let generation = sessionGeneration
        if !preservePlayback {
            isReconnecting = true
            if state != .connecting {
                transition(to: .connecting)
            }
        }
        do {
            try await reopenSocket()
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            if case .failed = state {
                isReconnecting = false
                return
            }
            let hasPendingTurn = await audioController.hasPendingTurnFile()
            let canResend = resumeTurn && !turnAccepted && hasPendingTurn
            if canResend {
                try await resendPendingTurn()
            }
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            if case .failed = state {
                isReconnecting = false
                return
            }
            automaticRecoveryLeft = 1
            isReconnecting = false
            if canResend {
                return
            }
            if !preservePlayback {
                transition(to: .ready)
            }
        } catch {
            isReconnecting = false
            throw error
        }
    }

    private func reopenSocket() async throws {
        let endpoint = try resolvedEndpoint(nil)
        let credential = try resolvedCredential(nil)
        let session = try await sessionClient.createSession(
            endpoint: endpoint,
            credential: credential,
            appSessionId: appSessionID
        )
        let history = transcriptsForResume()
        if await gatewayClient.hasOpenEventStream {
            try await gatewayClient.renewConnection(to: session, transcripts: history)
        } else {
            try await gatewayClient.connect(to: session, transcripts: history)
            listenToGateway()
        }
        appSessionID = session.appSessionId
        model = session.model
        audioSettings = session.audio
        renewalStopped = false
        renewalTask = nil
        scheduleTokenRenewal(at: Self.expirationDate(from: session.expiresAt))
        DiagnosticLog.connection.info(
            "Reconnected app session \(session.appSessionId, privacy: .public)"
        )
    }

    private func transcriptsForResume() -> [ConversationTranscript] {
        guard uploadInterrupted, !turnAccepted else { return transcripts }
        if transcripts.count > committedTranscriptCount {
            transcripts = Array(transcripts.prefix(committedTranscriptCount))
        }
        return transcripts
    }

    private func resendPendingTurn() async throws {
        guard let settings = audioSettings else {
            throw GatewayClientError.notConnected
        }
        guard let pcm = await audioController.pendingTurnPCM() else { return }
        await gatewayClient.clearInputBuffer()
        try await gatewayClient.sendPCM(
            pcm,
            sampleRate: settings.sampleRate,
            channels: settings.channels
        )
        DiagnosticLog.audio.info(
            "Resent \(pcm.count, privacy: .public) bytes session=\(self.sessionLabel, privacy: .public)"
        )
        try await commitLiveTurn()
    }

    private func commitLiveTurn() async throws {
        try await gatewayClient.commitTurn()
        responseOpen = true
        commitDate = Date()
        loggedFirstAudioLatency = false
        DiagnosticLog.audio.info(
            "Committed spoken turn session=\(self.sessionLabel, privacy: .public)"
        )
        transition(to: .waiting)
    }

    private func presentConnectionLost() async {
        isReconnecting = false
        if state == .playing {
            failureAfterPlayback = ConversationState.connectionLostMessage
            return
        }
        await failVisibleSession(ConversationState.connectionLostMessage, endSession: false)
    }

    private func playPreviewResponse(_ audioSettings: RealtimeSession.AudioSettings?) {
        guard let audioSettings else {
            transition(to: .ready)
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
                self.transition(to: .playing)
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
                self.transition(to: .ready)
            } catch {
                DiagnosticLog.audio.error(
                    "Preview playback failed: \(error.localizedDescription, privacy: .public)"
                )
                self.transition(to: .failed(Self.message(for: error)))
            }
        }
    }

    private func watchPlaybackUntilFinished() {
        playbackWatchTask?.cancel()
        playbackWatchTask = Task { [weak self] in
            guard let self else { return }
            await self.audioController.waitUntilPlaybackFinished()
            guard !Task.isCancelled, self.state == .playing else { return }
            if let message = self.failureAfterPlayback {
                self.failureAfterPlayback = nil
                await self.failVisibleSession(message, endSession: false)
                return
            }
            if self.turnAccepted || !self.uploadInterrupted {
                await self.audioController.deleteTurnFile()
            }
            self.transition(to: .ready)
        }
    }

    private func interruptAudio() async {
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: true)
        await stopCaptureTasks(deleteTurnFile: true)
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard state == .recording else { return }
        DiagnosticLog.audio.error(
            "Capture failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        await interruptAudio()
        transition(to: .failed(Self.message(for: error)))
    }

    private func stopCaptureTasks(deleteTurnFile: Bool) async {
        captureTask?.cancel()
        captureTask = nil
        _ = await audioController.stopCapture()
        if deleteTurnFile {
            await audioController.deleteTurnFile()
        }
    }

    private func startAudioProblemListener() {
        guard audioProblemTask == nil else { return }
        audioProblemTask = Task { [weak self] in
            guard let self else { return }
            for await problem in await self.audioController.problems() {
                await self.handleAudioProblem(problem)
            }
        }
    }

    private func handleAudioProblem(_ error: AudioControllerError) async {
        switch error {
        case .noResponseToReplay:
            return
        case .microphoneDenied, .audioRouteUnavailable, .playbackUnavailable, .unavailableInput:
            break
        }
        guard state == .recording || state == .waiting || state == .playing else { return }
        let message = Self.message(for: error)
        DiagnosticLog.audio.error(
            "\(message, privacy: .public) session=\(self.sessionLabel, privacy: .public)"
        )
        responseOpen = false
        await interruptAudio()
        transition(to: .failed(message))
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
        if renewalInFlight || isReconnecting || recoveryTask != nil { return }
        if case .failed = state { return }

        renewalInFlight = true
        defer { renewalInFlight = false }

        while state != .ready || actionInFlight || isReconnecting {
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
            DiagnosticLog.connection.info(
                "Renewed the model session token session=\(session.appSessionId, privacy: .public)"
            )
        } catch {
            DiagnosticLog.connection.error(
                "Token renewal failed session=\(self.sessionLabel, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            guard !renewalStopped, appSessionID == currentSessionID else { return }
            if Self.shouldShowRenewalFailure(error) {
                await failVisibleSession(Self.message(for: error), endSession: true)
                return
            }
            if await gatewayClient.isConnected {
                renewalTask = nil
                scheduleTokenRenewal(at: Date().addingTimeInterval(20))
                return
            }
            scheduleRecovery(resumeTurn: false, userInitiated: false)
        }
    }

    private func failVisibleSession(_ message: String, endSession: Bool) async {
        if case .failed = state { return }
        responseOpen = false
        isReconnecting = false
        renewalStopped = true
        renewalTask?.cancel()
        renewalTask = nil
        playbackWatchTask?.cancel()
        playbackWatchTask = nil
        await audioController.stopPlayback(keepLastResponse: !endSession)
        if endSession {
            hasLastResponse = false
            let label = sessionLabel
            transcripts = []
            committedTranscriptCount = 0
            turnAccepted = false
            uploadInterrupted = false
            eventTask?.cancel()
            eventTask = nil
            await stopCaptureTasks(deleteTurnFile: true)
            await gatewayClient.disconnect()
            appSessionID = nil
            model = nil
            audioSettings = nil
            DiagnosticLog.connection.info("Ended app session \(label, privacy: .public)")
        } else {
            await stopCaptureTasks(deleteTurnFile: false)
        }
        transition(to: .failed(message))
    }

    private static func shouldShowRenewalFailure(_ error: Error) -> Bool {
        guard case .httpStatus(let code) = error as? SessionClientError else {
            return false
        }
        return (400..<500).contains(code)
    }

    private static func isRecoverableNetwork(_ error: Error) -> Bool {
        if let gateway = error as? GatewayClientError {
            switch gateway {
            case .timeout, .notConnected:
                return true
            case .encodingFailed:
                return false
            }
        }
        if error is URLError {
            return true
        }
        return (error as NSError).domain == NSURLErrorDomain
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
        DiagnosticLog.transcript.info(
            "session=\(self.sessionLabel, privacy: .public) role=user text=\(text, privacy: .public)"
        )
    }

    private func storeAssistantDelta(itemID: String, delta: String) {
        guard canStoreTranscript else { return }
        upsertTranscript(id: "assistant-\(itemID)", role: .assistant, text: delta, append: true)
    }

    private func storeAssistantDone(itemID: String, text: String) {
        guard canStoreTranscript else { return }
        let id = "assistant-\(itemID)"
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            upsertTranscript(id: id, role: .assistant, text: text, append: false)
        }
        let stored = transcripts.first(where: { $0.id == id })?.text ?? text
        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DiagnosticLog.transcript.info(
            "session=\(self.sessionLabel, privacy: .public) role=assistant text=\(stored, privacy: .public)"
        )
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
        if turnAccepted {
            committedTranscriptCount = transcripts.count
        }
    }

    private func logFirstAudioLatency() {
        guard !loggedFirstAudioLatency, let commitDate else { return }
        loggedFirstAudioLatency = true
        let milliseconds = Int(Date().timeIntervalSince(commitDate) * 1000)
        DiagnosticLog.latency.info(
            "First audio \(milliseconds, privacy: .public) ms session=\(self.sessionLabel, privacy: .public)"
        )
    }

    private func logResponseLatency() {
        guard let commitDate else { return }
        let milliseconds = Int(Date().timeIntervalSince(commitDate) * 1000)
        DiagnosticLog.latency.info(
            "Response done \(milliseconds, privacy: .public) ms session=\(self.sessionLabel, privacy: .public)"
        )
        self.commitDate = nil
    }

    private var sessionLabel: String {
        appSessionID ?? "none"
    }

    private func transition(to newState: ConversationState) {
        let old = state
        state = newState
        guard old != newState else { return }
        switch newState {
        case .recording:
            signal(.start)
        case .waiting:
            signal(.stop)
        case .playing:
            signal(.success)
        case .ready:
            signal(.click)
        case .failed:
            signal(.failure)
        case .connecting:
            break
        }
    }

    private func signal(_ kind: HapticSignal.Kind) {
        hapticToken += 1
        hapticSignal = HapticSignal(kind: kind, token: hapticToken)
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
            switch audioError {
            case .microphoneDenied:
                return ConversationState.microphoneDeniedMessage
            case .audioRouteUnavailable, .unavailableInput, .playbackUnavailable:
                return ConversationState.audioRouteMessage
            case .noResponseToReplay:
                return audioError.localizedDescription
            }
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
