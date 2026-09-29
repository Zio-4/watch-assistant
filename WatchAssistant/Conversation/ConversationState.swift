import SwiftUI

struct ConversationTranscript: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    var text: String
}

enum ConversationState: Equatable, Sendable {
    case connecting
    case ready
    case recording
    case waiting
    case playing
    case failed(String)

    static let sessionEndedMessage = "Tap Retry to connect."
    static let microphoneDeniedMessage = "Allow the microphone in Settings."
    static let audioRouteMessage = "Speaker or microphone unavailable."
    static let connectionLostMessage = "Connection lost. Tap Retry."

    var title: String {
        displayTitle(reconnecting: false)
    }

    func displayTitle(reconnecting: Bool) -> String {
        if reconnecting { return "Reconnecting" }
        switch self {
        case .connecting: return "Connecting"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .waiting: return "Thinking"
        case .playing: return "Speaking"
        case .failed(let message) where message == Self.sessionEndedMessage: return "Ended"
        case .failed(let message) where message == Self.microphoneDeniedMessage: return "Microphone"
        case .failed(let message) where message == Self.audioRouteMessage: return "Audio"
        case .failed(let message) where message == Self.connectionLostMessage: return "Offline"
        case .failed: return "Failed"
        }
    }

    var detail: String {
        displayDetail(reconnecting: false)
    }

    func displayDetail(reconnecting: Bool) -> String {
        if reconnecting { return "Restoring session" }
        switch self {
        case .connecting: return "Opening session"
        case .ready: return "Tap Talk"
        case .recording: return "Tap Done"
        case .waiting: return "Waiting"
        case .playing: return "On speaker"
        case .failed(let message): return message
        }
    }

    var symbolName: String {
        switch self {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .ready: "checkmark.circle.fill"
        case .recording: "waveform.circle.fill"
        case .waiting: "ellipsis.circle.fill"
        case .playing: "speaker.wave.2.circle.fill"
        case .failed(let message) where message == Self.microphoneDeniedMessage: "mic.slash.circle.fill"
        case .failed(let message) where message == Self.audioRouteMessage: "speaker.slash.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .connecting, .waiting: .yellow
        case .ready: .green
        case .recording: .red
        case .playing: .blue
        case .failed: .orange
        }
    }

    var primaryActionTitle: String? {
        switch self {
        case .ready: "Talk"
        case .recording: "Done"
        case .playing: "Reply"
        case .failed: "Retry"
        case .connecting, .waiting: nil
        }
    }

    var showsEndAction: Bool {
        switch self {
        case .ready, .recording, .waiting, .playing: true
        case .connecting, .failed: false
        }
    }

    var showsReplayAction: Bool {
        switch self {
        case .ready, .playing: true
        case .connecting, .recording, .waiting, .failed: false
        }
    }
}

struct HapticSignal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case start
        case stop
        case success
        case failure
        case click
    }

    let kind: Kind
    let token: Int
}

