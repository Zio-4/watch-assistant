import Foundation

actor GatewayClient {
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var openWaiter: WebSocketOpenWaiter?
    private var receiveTask: Task<Void, Never>?
    private var eventStream: AsyncStream<GatewayServerEvent>?
    private var eventContinuation: AsyncStream<GatewayServerEvent>.Continuation?

    func connect(to session: RealtimeSession) async throws {
        disconnect()

        let events = AsyncStream<GatewayServerEvent>.makeStream()
        eventStream = events.stream
        eventContinuation = events.continuation

        let waiter = WebSocketOpenWaiter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let urlSession = URLSession(configuration: configuration, delegate: waiter, delegateQueue: nil)
        let protocols = [
            "ai-gateway-realtime.v1",
            "ai-gateway-auth.\(session.token)",
        ]
        let socket = urlSession.webSocketTask(with: session.url, protocols: protocols)
        self.openWaiter = waiter
        self.urlSession = urlSession
        self.webSocket = socket
        socket.resume()

        do {
            try await waiter.waitUntilOpen(timeout: 15)
            listenForMessages(socket)
            try await sendJSON(GatewaySessionUpdate.phaseOne(session: session))
        } catch {
            disconnect()
            throw error
        }
    }

    func events() -> AsyncStream<GatewayServerEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    func sendAudioChunk(_ pcm16: Data) async throws {
        try await sendJSON(GatewayInputAudioAppend(audio: pcm16.base64EncodedString()))
    }

    func commitTurn() async throws {
        try await sendJSON(GatewayInputAudioCommit())
        try await sendJSON(GatewayResponseCreate())
    }

    func disconnect() {
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

    private func listenForMessages(_ socket: URLSessionWebSocketTask) {
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
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
                    if !Task.isCancelled {
                        eventContinuation?.yield(.connectionClosed(error.localizedDescription))
                        eventContinuation?.finish()
                    }
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
