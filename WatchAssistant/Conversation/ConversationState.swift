import SwiftUI

enum ConversationState: Equatable, Sendable {
    case connecting
    case ready
    case recording
    case waiting
    case playing
    case failed(String)

    var title: String {
        switch self {
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .recording: "Listening"
        case .waiting: "Thinking"
        case .playing: "Speaking"
        case .failed: "Connection failed"
        }
    }

    var detail: String {
        switch self {
        case .connecting: "Opening a secure model session"
        case .ready: "Session connected"
        case .recording: "Tap Done when you finish"
        case .waiting: "Waiting for a response"
        case .playing: "Playing through the watch speaker"
        case .failed(let message): message
        }
    }

    var symbolName: String {
        switch self {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .ready: "checkmark.circle.fill"
        case .recording: "waveform.circle.fill"
        case .waiting: "ellipsis.circle.fill"
        case .playing: "speaker.wave.2.circle.fill"
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
}

