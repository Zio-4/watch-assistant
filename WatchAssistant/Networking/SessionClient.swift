import Foundation

struct RealtimeSession: Decodable, Sendable {
    struct AudioSettings: Decodable, Sendable {
        let inputFormat: String
        let outputFormat: String
        let sampleRate: Int
        let channels: Int
    }

    let appSessionId: String
    let model: String
    let url: URL
    let token: String
    let expiresAt: String
    let audio: AudioSettings
}

struct SessionClient: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func createSession(endpoint: URL, credential: String) async throws -> RealtimeSession {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("WatchAssistant/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SessionClientError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(RealtimeSession.self, from: data)
        } catch {
            throw SessionClientError.invalidResponse
        }
    }
}

enum SessionClientError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The session service returned an invalid response."
        case .httpStatus(401):
            "The personal app credential was rejected."
        case .httpStatus(403):
            "Vercel blocked the request (403). Turn off Deployment Protection for production."
        case .httpStatus(404):
            "No function at this URL (404). Use https://YOUR-APP.vercel.app/api/realtime/session"
        case .httpStatus(405):
            "This URL does not accept POST (405)."
        case .httpStatus(429):
            "Too many connection attempts. Wait one minute and retry."
        case .httpStatus(500):
            "Session service is missing env vars (500)."
        case .httpStatus(502):
            "AI Gateway could not mint a token (502)."
        case .httpStatus(let code):
            "Session service returned HTTP \(code)."
        }
    }
}
