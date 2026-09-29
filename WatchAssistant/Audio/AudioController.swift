import AVFoundation
import Foundation

actor AudioController {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var writer: TurnWriter?
    private var turnFileURL: URL?
    private var tapInstalled = false
    private var isCapturing = false
    private var silenceTask: Task<Void, Never>?
    private var playerAttached = false
    private var playbackFormat: AVAudioFormat?
    private var lastResponse = Data()
    private var preroll = Data()
    private var pendingPlaybackBuffers = 0
    private var playbackInputFinished = false
    private var playbackStarted = false
    private var isPlaybackActive = false
    private var playbackWaiters: [CheckedContinuation<Void, Never>] = []
    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var problemStream: AsyncStream<AudioControllerError>?
    private var problemContinuation: AsyncStream<AudioControllerError>.Continuation?

    /// About 80 ms of 24 kHz mono PCM16, enough to start the player without waiting for the full reply.
    private let playbackStartThresholdBytes = 3_840

    var hasLastResponse: Bool {
        !lastResponse.isEmpty
    }

    func problems() -> AsyncStream<AudioControllerError> {
        if let problemStream {
            return problemStream
        }
        let stream = AsyncStream<AudioControllerError>.makeStream()
        problemStream = stream.stream
        problemContinuation = stream.continuation
        return stream.stream
    }

    func resolveMicrophoneAccess() async -> Bool {
        let status = await MainActor.run { AVAudioApplication.shared.recordPermission }
        switch status {
        case .granted:
            return true
        case .denied:
            DiagnosticLog.audio.error("Microphone permission denied")
            return false
        case .undetermined:
            let granted = await Self.requestMicrophoneAccess()
            if !granted {
                DiagnosticLog.audio.error("Microphone permission denied")
            }
            return granted
        @unknown default:
            DiagnosticLog.audio.error("Microphone permission denied")
            return false
        }
    }

    func prepareAudioRoute() async throws {
        try await activateAudioSession()
        startRouteObservation()
    }

    func hasPendingTurnFile() -> Bool {
        guard let turnFileURL else { return false }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: turnFileURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        return bytes > 0
    }

    func pendingTurnPCM() -> Data? {
        guard let turnFileURL else { return nil }
        guard let data = try? Data(contentsOf: turnFileURL), !data.isEmpty else { return nil }
        return data
    }

    func startCapture(sampleRate: Int, channels: Int) async throws -> AsyncThrowingStream<Data, Error> {
        if isPlaybackActive {
            stopPlayback(keepLastResponse: true)
        }
        if isCapturing {
            _ = await stopCapture()
        }
        if let existingTurn = turnFileURL {
            try? FileManager.default.removeItem(at: existingTurn)
            turnFileURL = nil
        }

        let granted = await resolveMicrophoneAccess()
        guard granted else {
            throw AudioControllerError.microphoneDenied
        }

        try await activateAudioSession()
        startRouteObservation()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        // Simulator-only: Watch Simulator often reports 0 Hz, so Talk has no mic buffers.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            #if targetEnvironment(simulator)
            DiagnosticLog.audio.info("Microphone format unavailable; using silence for this turn")
            return try startSilenceCapture(sampleRate: sampleRate, channels: max(channels, 1))
            #else
            DiagnosticLog.audio.error("Microphone route unavailable")
            throw AudioControllerError.audioRouteUnavailable
            #endif
        }

        let outputFormat = try AudioFormatConverter.makeOutputFormat(
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(max(channels, 1))
        )
        let converter = try AudioFormatConverter.makeConverter(from: inputFormat, to: outputFormat)
        let pipe = ConversionPipe(converter: converter, outputFormat: outputFormat)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-assistant-turn-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        turnFileURL = url

        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        let writer = TurnWriter(handle: handle, continuation: stream.continuation)
        self.writer = writer

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            do {
                let data = try pipe.convert(buffer)
                guard !data.isEmpty else { return }
                writer.append(data)
            } catch {
                writer.fail(error)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            DiagnosticLog.audio.error(
                "Audio engine failed: \(error.localizedDescription, privacy: .public)"
            )
            await cleanupCapture(finishStream: true)
            await deleteTurnFile()
            throw AudioControllerError.audioRouteUnavailable
        }

        isCapturing = true
        DiagnosticLog.audio.info("Started capture at \(sampleRate, privacy: .public) Hz")
        return stream.stream
    }

    func stopCapture() async -> URL? {
        await cleanupCapture(finishStream: true)
        return turnFileURL
    }

    func deleteTurnFile() async {
        if let turnFileURL {
            try? FileManager.default.removeItem(at: turnFileURL)
        }
        self.turnFileURL = nil
    }

    func enqueuePlayback(_ pcm16: Data, sampleRate: Int, channels: Int) async throws {
        guard !pcm16.isEmpty else { return }
        if !isPlaybackActive {
            try await beginPlaybackSession(sampleRate: sampleRate, channels: channels)
        }
        lastResponse.append(pcm16)
        if playbackStarted {
            try schedulePlayback(pcm16)
            return
        }

        preroll.append(pcm16)
        if preroll.count >= playbackStartThresholdBytes || playbackInputFinished {
            try startPlayer(with: preroll)
            preroll = Data()
        }
    }

    func markPlaybackInputFinished() async throws {
        playbackInputFinished = true
        if !isPlaybackActive {
            finishPlayback()
            return
        }
        if !playbackStarted {
            if preroll.isEmpty {
                finishPlayback()
                return
            }
            try startPlayer(with: preroll)
            preroll = Data()
        }
        if playbackStarted && pendingPlaybackBuffers == 0 {
            finishPlayback()
        }
    }

    func waitUntilPlaybackFinished() async {
        if !isPlaybackActive {
            return
        }
        await withCheckedContinuation { continuation in
            playbackWaiters.append(continuation)
        }
    }

    func replayLastResponse() async throws {
        let pcm16 = lastResponse
        guard !pcm16.isEmpty else {
            throw AudioControllerError.noResponseToReplay
        }
        let sampleRate = Int(playbackFormat?.sampleRate ?? 24_000)
        let channels = Int(playbackFormat?.channelCount ?? 1)
        stopPlayback(keepLastResponse: true)
        try await beginPlaybackSession(sampleRate: sampleRate, channels: max(channels, 1))
        lastResponse = pcm16
        playbackInputFinished = true
        try startPlayer(with: pcm16)
    }

    func stopPlayback(keepLastResponse: Bool = true) {
        playerNode.stop()
        playerNode.reset()
        pendingPlaybackBuffers = 0
        playbackInputFinished = true
        playbackStarted = false
        preroll = Data()
        if engine.isRunning && !isCapturing {
            engine.stop()
        }
        if !keepLastResponse {
            lastResponse = Data()
            playbackFormat = nil
        }
        finishPlayback()
    }

    /// Simulator-only fallback that emits silent PCM so Talk/Done still complete a turn.
    private func startSilenceCapture(sampleRate: Int, channels: Int) throws -> AsyncThrowingStream<Data, Error> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-assistant-turn-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        turnFileURL = url

        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        let writer = TurnWriter(handle: handle, continuation: stream.continuation)
        self.writer = writer

        let frameCount = max(sampleRate / 50, 1)
        let chunk = Data(count: frameCount * channels * MemoryLayout<Int16>.size)
        silenceTask = Task {
            while !Task.isCancelled {
                writer.append(chunk)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        isCapturing = true
        DiagnosticLog.audio.info("Started silence capture at \(sampleRate, privacy: .public) Hz")
        return stream.stream
    }

    private func beginPlaybackSession(sampleRate: Int, channels: Int) async throws {
        try await activateAudioSession()
        startRouteObservation()

        playbackFormat = try AudioFormatConverter.makePlaybackFormat(
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(max(channels, 1))
        )
        lastResponse = Data()
        preroll = Data()
        pendingPlaybackBuffers = 0
        playbackInputFinished = false
        playbackStarted = false
        isPlaybackActive = true

        if !playerAttached {
            engine.attach(playerNode)
            playerAttached = true
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    }

    private func startPlayer(with pcm16: Data) throws {
        guard playbackFormat != nil else {
            throw AudioControllerError.playbackUnavailable
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                DiagnosticLog.audio.error(
                    "Playback route failed: \(error.localizedDescription, privacy: .public)"
                )
                throw AudioControllerError.audioRouteUnavailable
            }
        }
        try schedulePlayback(pcm16)
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playbackStarted = true
        DiagnosticLog.audio.info("Started response playback")
    }

    private func schedulePlayback(_ pcm16: Data) throws {
        guard let playbackFormat else {
            throw AudioControllerError.playbackUnavailable
        }
        let bytesPerFrame = MemoryLayout<Int16>.size * Int(max(playbackFormat.channelCount, 1))
        let chunkSize = max(bytesPerFrame * 4_800, bytesPerFrame)
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + chunkSize, pcm16.count)
            let alignedEnd = end - ((end - offset) % bytesPerFrame)
            defer { offset = alignedEnd }
            guard alignedEnd > offset else { continue }
            let buffer = try AudioFormatConverter.playbackBuffer(
                fromPcm16: Data(pcm16[offset..<alignedEnd]),
                format: playbackFormat
            )
            pendingPlaybackBuffers += 1
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task {
                    await self?.bufferDidFinishPlaying()
                }
            }
        }
    }

    private func bufferDidFinishPlaying() {
        guard pendingPlaybackBuffers > 0 else { return }
        pendingPlaybackBuffers -= 1
        if playbackInputFinished && pendingPlaybackBuffers == 0 {
            finishPlayback()
        }
    }

    private func finishPlayback() {
        isPlaybackActive = false
        playbackStarted = false
        preroll = Data()
        pendingPlaybackBuffers = 0
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if engine.isRunning && !isCapturing {
            engine.stop()
        }
        let waiters = playbackWaiters
        playbackWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cleanupCapture(finishStream: Bool) async {
        silenceTask?.cancel()
        silenceTask = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        writer?.close(finishStream: finishStream)
        writer = nil
        isCapturing = false
    }

    private func activateAudioSession() async throws {
        do {
            try await MainActor.run {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
                try session.setActive(true)
            }
        } catch {
            DiagnosticLog.audio.error(
                "Audio session failed: \(error.localizedDescription, privacy: .public)"
            )
            throw AudioControllerError.audioRouteUnavailable
        }
    }

    private func startRouteObservation() {
        guard routeObserver == nil else { return }
        let center = NotificationCenter.default
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { await self?.handleRouteChange(reason: reason) }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            Task { await self?.handleInterruption(type: type) }
        }
    }

    private func handleRouteChange(reason: UInt?) {
        guard isCapturing || isPlaybackActive else { return }
        guard let reason, let change = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }
        switch change {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory:
            DiagnosticLog.audio.error("Audio route lost reason=\(reason, privacy: .public)")
            problemContinuation?.yield(.audioRouteUnavailable)
        default:
            break
        }
    }

    private func handleInterruption(type: UInt?) {
        guard isCapturing || isPlaybackActive else { return }
        guard let type, AVAudioSession.InterruptionType(rawValue: type) == .began else { return }
        DiagnosticLog.audio.error("Audio route interrupted")
        problemContinuation?.yield(.audioRouteUnavailable)
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum AudioControllerError: LocalizedError, Sendable {
    case microphoneDenied
    case unavailableInput
    case audioRouteUnavailable
    case playbackUnavailable
    case noResponseToReplay

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Allow the microphone in Settings."
        case .unavailableInput, .audioRouteUnavailable:
            "Speaker or microphone unavailable."
        case .playbackUnavailable:
            "The watch speaker could not start playback."
        case .noResponseToReplay:
            "There is no reply to replay yet."
        }
    }
}

private final class ConversionPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try AudioFormatConverter.pcm16Data(
            from: buffer,
            using: converter,
            outputFormat: outputFormat
        )
    }
}

private final class TurnWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var finished = false

    init(handle: FileHandle, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.handle = handle
        self.continuation = continuation
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        do {
            try handle?.write(contentsOf: data)
            continuation.yield(data)
        } catch {
            finished = true
            continuation.finish(throwing: error)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.finish(throwing: error)
    }

    func close(finishStream: Bool) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        guard finishStream, !finished else { return }
        finished = true
        continuation.finish()
    }
}
