import Foundation

enum AppConfiguration {
    static let sessionServiceURLKey = "sessionServiceURL"

    static var defaultSessionServiceURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SESSION_SERVICE_URL") as? String ?? ""
    }

    static var sessionServiceURL: URL? {
        let stored = UserDefaults.standard.string(forKey: sessionServiceURLKey)
        let candidate = stored?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (candidate?.isEmpty == false ? candidate : nil)
            ?? defaultSessionServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { return nil }
        return URL(string: resolved)
    }
}
