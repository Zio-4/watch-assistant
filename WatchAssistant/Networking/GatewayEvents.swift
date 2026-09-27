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

struct GatewayInputAudioAppend: Encodable, Sendable {
    let type = "input-audio-append"
    let audio: String
}

struct GatewayInputAudioCommit: Encodable, Sendable {
    let type = "input-audio-commit"
}

struct GatewayResponseCreate: Encodable, Sendable {
    let type = "response-create"
}

enum GatewayServerEvent: Equatable, Sendable {
    case audioCommitted
    case audioReceived(Data)
    case responseDone
    case error(String)
    case connectionClosed(String)
    case ignored

    static func parse(text: String) -> GatewayServerEvent {
        guard let data = text.data(using: .utf8) else { return .ignored }
        return parse(data: data)
    }

    static func parse(data: Data) -> GatewayServerEvent {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return .ignored
        }

        switch raw.type {
        case "audio-committed", "input_audio_buffer.committed":
            return .audioCommitted
        case "audio-delta",
             "response.audio.delta",
             "response.output_audio.delta",
             "response.output_audio_delta":
            guard let payload = raw.delta ?? raw.audio,
                  let pcm = Data(base64Encoded: payload),
                  !pcm.isEmpty
            else {
                return .ignored
            }
            return .audioReceived(pcm)
        case "response-done", "response.done":
            return .responseDone
        case "error":
            let message = raw.error?.message ?? raw.message ?? "The model session failed."
            return .error(message)
        default:
            return .ignored
        }
    }

    private struct Raw: Decodable {
        struct NestedError: Decodable {
            let message: String?
        }

        let type: String
        let message: String?
        let error: NestedError?
        let delta: String?
        let audio: String?
    }
}
