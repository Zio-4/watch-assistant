import Foundation

actor GatewayClient {
    private var urlSession: URLSession?
    private var webSocket: URLSessionWebSocketTask?

    func connect(to session: RealtimeSession) async throws {
        disconnect()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let urlSession = URLSession(configuration: configuration)
        let protocols = [
            "ai-gateway-realtime.v1",
            "ai-gateway-auth.\(session.token)",
        ]
        let socket = urlSession.webSocketTask(with: session.url, protocols: protocols)
        self.urlSession = urlSession
        self.webSocket = socket
        socket.resume()

        do {
            try await ping(socket)
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
            throw error
        }
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocket = nil
        urlSession = nil
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum GatewayClientError: Error {
    case encodingFailed
}
