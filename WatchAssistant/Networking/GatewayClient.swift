import Foundation

actor GatewayClient {
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var openWaiter: WebSocketOpenWaiter?
    private var receiveTask: Task<Void, Never>?
    private var eventStream: AsyncStream<GatewayServerEvent>?
    private var eventContinuation: AsyncStream<GatewayServerEvent>.Continuation?
    private var socketGeneration = 0
    private var socketFailed = false

    var isConnected: Bool {
        webSocket != nil && !socketFailed
    }

    var hasOpenEventStream: Bool {
        eventContinuation != nil
    }

    func connect(
        to session: RealtimeSession,
        transcripts: [ConversationTranscript] = []
    ) async throws {
        disconnect()

        let events = AsyncStream<GatewayServerEvent>.makeStream()
        eventStream = events.stream
        eventContinuation = events.continuation

        let opened: OpenSocket
        do {
            opened = try await openWebSocket(session)
        } catch {
            eventContinuation?.finish()
            eventContinuation = nil
            eventStream = nil
            throw error
        }

        adopt(opened)
        do {
            try await sendJSON(
                GatewaySessionUpdate.configured(session: session, transcripts: transcripts)
            )
        } catch {
            disconnect()
            throw error
        }
    }

    /// Opens a replacement WebSocket with a new client secret. The event stream
    /// stays open, and earlier transcripts are copied into the new session so
    /// the conversation continues.
    func renewConnection(
        to session: RealtimeSession,
        transcripts: [ConversationTranscript]
    ) async throws {
        let opened = try await openWebSocket(session)
        adopt(opened)
        do {
            try await sendJSON(
                GatewaySessionUpdate.configured(session: session, transcripts: transcripts)
            )
        } catch {
            socketFailed = true
            throw error
        }
    }

    func events() -> AsyncStream<GatewayServerEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    func sendAudioChunk(_ pcm16: Data) async throws {
        try await sendJSON(GatewayInputAudioAppend(audio: pcm16.base64EncodedString()))
    }

    func sendPCM(_ pcm16: Data, sampleRate: Int, channels: Int) async throws {
        let bytesPerFrame = max(channels, 1) * MemoryLayout<Int16>.size
        guard bytesPerFrame > 0, !pcm16.isEmpty else { return }
        let chunkSize = max(bytesPerFrame * max(sampleRate / 10, 1), bytesPerFrame)
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + chunkSize, pcm16.count)
            let alignedEnd = end - ((end - offset) % bytesPerFrame)
            if alignedEnd <= offset { break }
            try await sendAudioChunk(Data(pcm16[offset..<alignedEnd]))
            offset = alignedEnd
        }
    }

    func commitTurn() async throws {
        try await sendJSON(GatewayInputAudioCommit())
        try await sendJSON(GatewayResponseCreate())
    }

    func cancelActiveResponse() async {
        guard isConnected else { return }
        try? await sendJSON(GatewayResponseCancel())
    }

    func clearInputBuffer() async {
        guard isConnected else { return }
        try? await sendJSON(GatewayInputAudioClear())
    }

    func disconnect() {
        socketGeneration += 1
        socketFailed = false
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
        openWaiter = nil
    }

    private struct OpenSocket {
        let socket: URLSessionWebSocketTask
        let urlSession: URLSession
        let waiter: WebSocketOpenWaiter
    }

    private func openWebSocket(_ session: RealtimeSession) async throws -> OpenSocket {
        let waiter = WebSocketOpenWaiter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let urlSession = URLSession(configuration: configuration, delegate: waiter, delegateQueue: nil)
        let protocols = [
            "ai-gateway-realtime.v1",
            "ai-gateway-auth.\(session.token)",
        ]
        let socket = urlSession.webSocketTask(with: session.url, protocols: protocols)
        socket.resume()
        do {
            try await waiter.waitUntilOpen(timeout: 15)
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            urlSession.invalidateAndCancel()
            throw error
        }
        return OpenSocket(socket: socket, urlSession: urlSession, waiter: waiter)
    }

    private func adopt(_ opened: OpenSocket) {
        socketGeneration += 1
        let generation = socketGeneration
        let oldReceive = receiveTask
        let oldSocket = webSocket
        let oldSession = urlSession
        receiveTask = nil
        webSocket = opened.socket
        urlSession = opened.urlSession
        openWaiter = opened.waiter
        socketFailed = false
        oldReceive?.cancel()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
        oldSession?.invalidateAndCancel()
        listenForMessages(opened.socket, generation: generation)
    }

    private func sendJSON(_ value: some Encodable) async throws {
        guard let webSocket else {
            throw GatewayClientError.notConnected
        }
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayClientError.encodingFailed
        }
        try await webSocket.send(.string(text))
    }

    private func listenForMessages(_ socket: URLSessionWebSocketTask, generation: Int) {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard generation == self.socketGeneration else { return }
                    let event: GatewayServerEvent
                    switch message {
                    case .string(let text):
                        event = GatewayServerEvent.parse(text: text)
                    case .data(let data):
                        event = GatewayServerEvent.parse(data: data)
                    @unknown default:
                        event = .ignored
                    }
                    if event != .ignored {
                        eventContinuation?.yield(event)
                    }
                } catch {
                    guard generation == self.socketGeneration, !Task.isCancelled else { return }
                    socketFailed = true
                    eventContinuation?.yield(.connectionClosed(error.localizedDescription))
                    break
                }
            }
        }
    }
}

enum GatewayClientError: LocalizedError {
    case encodingFailed
    case timeout
    case notConnected

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The model session could not be configured."
        case .timeout:
            "The model session did not open in time."
        case .notConnected:
            "The model session is not connected."
        }
    }
}

private final class WebSocketOpenWaiter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var opened = false
    private var failure: Error?

    func waitUntilOpen(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitForOpenEvent() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayClientError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func waitForOpenEvent() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol: String?
    ) {
        finish(error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(error: error)
    }

    private func finish(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            failure = error
        } else {
            opened = true
        }
        continuation?.resume(with: error.map { .failure($0) } ?? .success(()))
        continuation = nil
    }
}
