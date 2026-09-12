import AVFoundation
import Foundation

actor AudioController {
    private let engine = AVAudioEngine()
    private var writer: TurnWriter?
    private var turnFileURL: URL?
    private var tapInstalled = false
    private var isCapturing = false
    private var silenceTask: Task<Void, Never>?

    func startCapture(sampleRate: Int, channels: Int) async throws -> AsyncThrowingStream<Data, Error> {
        if isCapturing {
            _ = await stopCapture()
        }

        let granted = await Self.requestMicrophoneAccess()
        guard granted else {
            throw AudioControllerError.microphoneDenied
        }

        try await MainActor.run {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
            try session.setActive(true)
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        // Simulator-only: Watch Simulator often reports 0 Hz, so Talk has no mic buffers.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            DiagnosticLog.audio.info("Microphone format unavailable; using silence for this turn")
            return try startSilenceCapture(sampleRate: sampleRate, channels: max(channels, 1))
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
            await cleanupCapture(finishStream: true)
            throw error
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

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

enum AudioControllerError: LocalizedError {
    case microphoneDenied
    case unavailableInput

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is required to talk."
        case .unavailableInput:
            "The watch microphone is not available."
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
