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

        struct AudioTranscription: Encodable, Sendable {}

        let instructions: String
        let voice: String
        let outputModalities: [String]
        let inputAudioFormat: AudioFormat
        let outputAudioFormat: AudioFormat
        let inputAudioTranscription: AudioTranscription
        let outputAudioTranscription: AudioTranscription
        let turnDetection: TurnDetection
    }

    let type = "session-update"
    let config: Configuration

    static func configured(
        session: RealtimeSession,
        transcripts: [ConversationTranscript] = []
    ) -> Self {
        let input = Configuration.AudioFormat(
            type: session.audio.inputFormat,
            rate: session.audio.sampleRate
        )
        let output = Configuration.AudioFormat(
            type: session.audio.outputFormat,
            rate: session.audio.sampleRate
        )
        return Self(config: Configuration(
            instructions: instructions(including: transcripts),
            voice: "alloy",
            outputModalities: ["audio"],
            inputAudioFormat: input,
            outputAudioFormat: output,
            inputAudioTranscription: Configuration.AudioTranscription(),
            outputAudioTranscription: Configuration.AudioTranscription(),
            turnDetection: Configuration.TurnDetection(type: "disabled")
        ))
    }

    static func instructions(including transcripts: [ConversationTranscript]) -> String {
        let base = "You are a concise personal assistant on Apple Watch."
        let lines = transcripts.suffix(12).compactMap { transcript -> String? in
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = transcript.role == .user ? "User" : "Assistant"
            return "\(speaker): \(text)"
        }
        guard !lines.isEmpty else { return base }
        return """
        \(base) Continue this conversation using the earlier turns as context. Do not repeat those turns unless asked.
        \(lines.joined(separator: "\n"))
        """
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

struct GatewayResponseCancel: Encodable, Sendable {
    let type = "response-cancel"
}

struct GatewayInputAudioClear: Encodable, Sendable {
    let type = "input-audio-clear"
}

enum GatewayServerEvent: Equatable, Sendable {
    case audioCommitted
    case audioReceived(Data, itemID: String?)
    case inputTranscript(itemID: String, text: String)
    case assistantTranscriptDelta(itemID: String, delta: String)
    case assistantTranscriptDone(itemID: String, text: String)
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
            return .audioReceived(pcm, itemID: raw.itemId)
        case "input-transcription-completed",
             "conversation.item.input_audio_transcription.completed":
            guard let text = raw.transcript ?? raw.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .ignored
            }
            return .inputTranscript(itemID: raw.itemId ?? "user-current", text: text)
        case "audio-transcript-delta",
             "response.audio_transcript.delta",
             "response.output_audio_transcript.delta":
            guard let delta = raw.delta ?? raw.transcript ?? raw.text, !delta.isEmpty else {
                return .ignored
            }
            return .assistantTranscriptDelta(itemID: raw.itemId ?? "assistant-current", delta: delta)
        case "audio-transcript-done",
             "response.audio_transcript.done",
             "response.output_audio_transcript.done":
            return .assistantTranscriptDone(
                itemID: raw.itemId ?? "assistant-current",
                text: raw.transcript ?? raw.text ?? ""
            )
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
        let transcript: String?
        let text: String?
        let itemId: String?

        enum CodingKeys: String, CodingKey {
            case type
            case message
            case error
            case delta
            case audio
            case transcript
            case text
            case itemId
            case itemIDSnake = "item_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            error = try container.decodeIfPresent(NestedError.self, forKey: .error)
            delta = try container.decodeIfPresent(String.self, forKey: .delta)
            audio = try container.decodeIfPresent(String.self, forKey: .audio)
            transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            let camelItemID = try container.decodeIfPresent(String.self, forKey: .itemId)
            let snakeItemID = try container.decodeIfPresent(String.self, forKey: .itemIDSnake)
            itemId = camelItemID ?? snakeItemID
        }
    }
}
