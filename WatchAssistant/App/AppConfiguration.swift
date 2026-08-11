import Foundation

enum AppConfiguration {
    static let sessionServiceURLKey = "sessionServiceURL"

    static var defaultSessionServiceURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SESSION_SERVICE_URL") as? String ?? ""
    }

    static var sessionServiceURL: URL? {
        let stored = UserDefaults.standard.string(forKey: sessionServiceURLKey)
        return URL(string: stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultSessionServiceURL)
    }
}

