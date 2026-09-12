import Foundation
import OSLog

enum DiagnosticLog {
    static let connection = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WatchAssistant",
        category: "Connection"
    )

    static let audio = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WatchAssistant",
        category: "Audio"
    )
}
