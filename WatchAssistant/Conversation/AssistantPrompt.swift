import Foundation

enum AssistantPrompt {
    static let base = "You are a concise personal assistant on Apple Watch."
    static let continuation = "Continue this conversation using the earlier turns as context. Do not repeat those turns unless asked."
    static let recentTurnLimit = 12

    static func instructions(including transcripts: [ConversationTranscript]) -> String {
        let lines = transcripts.suffix(recentTurnLimit).compactMap { transcript -> String? in
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = transcript.role == .user ? "User" : "Assistant"
            return "\(speaker): \(text)"
        }
        guard !lines.isEmpty else { return base }
        return """
        \(base) \(continuation)
        \(lines.joined(separator: "\n"))
        """
    }
}
