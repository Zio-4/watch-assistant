import Foundation

struct GatewaySessionUpdate: Encodable, Sendable {
    struct Configuration: Encodable, Sendable {
        struct AudioFormat: Encodable, Sendable {
            let type: String
            let rate: Int
        }

        struct TurnDetection: Encodable, Sendable {
            let type: String
        }

        let instructions: String
        let voice: String
        let outputModalities: [String]
        let inputAudioFormat: AudioFormat
        let outputAudioFormat: AudioFormat
        let turnDetection: TurnDetection
    }

    let type = "session-update"
    let config: Configuration

    static func phaseOne(session: RealtimeSession) -> Self {
        let input = Configuration.AudioFormat(
            type: session.audio.inputFormat,
            rate: session.audio.sampleRate
        )
        let output = Configuration.AudioFormat(
            type: session.audio.outputFormat,
            rate: session.audio.sampleRate
        )
        return Self(config: Configuration(
            instructions: "You are a concise personal assistant on Apple Watch.",
            voice: "alloy",
            outputModalities: ["audio"],
            inputAudioFormat: input,
            outputAudioFormat: output,
            turnDetection: Configuration.TurnDetection(type: "disabled")
        ))
    }
}

