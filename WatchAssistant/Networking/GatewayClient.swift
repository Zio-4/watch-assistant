import Foundation

actor GatewayClient {
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?
    private var openWaiter: WebSocketOpenWaiter?

    func connect(to session: RealtimeSession) async throws {
        disconnect()

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
            let update = GatewaySessionUpdate.phaseOne(session: session)
            let data = try JSONEncoder().encode(update)
            guard let text = String(data: data, encoding: .utf8) else {
                throw GatewayClientError.encodingFailed
            }
            try await socket.send(.string(text))
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            urlSession.invalidateAndCancel()
            self.webSocket = nil
            self.urlSession = nil
            self.openWaiter = nil
            throw error
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
        openWaiter = nil
    }
}

enum GatewayClientError: LocalizedError {
    case encodingFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The model session could not be configured."
        case .timeout:
            "The model session did not open in time."
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
