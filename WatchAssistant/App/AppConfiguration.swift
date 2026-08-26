import Foundation

enum AppConfiguration {
    static let sessionServiceURLKey = "sessionServiceURL"
    static let sessionPath = "api/realtime/session"

    static var defaultSessionServiceURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SESSION_SERVICE_URL") as? String ?? ""
    }

    static var sessionServiceURL: URL? {
        let stored = UserDefaults.standard.string(forKey: sessionServiceURLKey)
        let candidate = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (candidate?.isEmpty == false ? candidate : nil)
            ?? defaultSessionServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedSessionServiceURL(from: resolved)
    }

    static func normalizedSessionServiceURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard var url = URL(string: trimmed), url.scheme == "https" || url.host == "localhost" else {
            return URL(string: trimmed)
        }
        if url.path.isEmpty || url.path == "/" {
            url.append(path: sessionPath)
        }
        return url
    }
}
