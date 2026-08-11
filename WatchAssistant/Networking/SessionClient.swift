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
    let expiresAt: Date
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(RealtimeSession.self, from: data)
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
        case .httpStatus(429):
            "Too many connection attempts. Wait one minute and retry."
        case .httpStatus:
            "The session service could not create a model session."
        }
    }
}

