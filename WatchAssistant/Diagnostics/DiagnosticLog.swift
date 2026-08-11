import Foundation
import OSLog

enum DiagnosticLog {
    static let connection = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WatchAssistant",
        category: "Connection"
    )
}

