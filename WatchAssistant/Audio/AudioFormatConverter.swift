import AVFoundation
import Foundation

enum AudioFormatConverter {
    static func makeOutputFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else {
            throw AudioConversionError.invalidFormat
        }
        return format
    }

    static func makeConverter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter {
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioConversionError.converterUnavailable
        }
        return converter
    }

    static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> Data {
        let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = max(AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)), 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioConversionError.allocationFailed
        }

        let once = SubmitOnce()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if once.done {
                status.pointee = .noDataNow
                return nil
            }
            once.done = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error else {
            throw AudioConversionError.conversionFailed
        }
        guard output.frameLength > 0 else {
            return Data()
        }
        return int16Data(from: output)
    }

    static func makePlaybackFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw AudioConversionError.invalidFormat
        }
        return format
    }

    static func playbackBuffer(fromPcm16 data: Data, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let channels = Int(max(format.channelCount, 1))
        let frameCount = data.count / (MemoryLayout<Int16>.size * channels)
        guard frameCount > 0 else {
            throw AudioConversionError.allocationFailed
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioConversionError.allocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            for channel in 0..<channels {
                guard let destination = buffer.floatChannelData?[channel] else { continue }
                var frame = 0
                while frame < frameCount {
                    destination[frame] = Float(source[frame * channels + channel]) / Float(Int16.max)
                    frame += 1
                }
            }
        }
        return buffer
    }

    static func previewTonePCM16(
        sampleRate: Int,
        channels: Int,
        seconds: Double = 2,
        frequency: Double = 440
    ) -> Data {
        let frameCount = max(Int(Double(sampleRate) * seconds), 1)
        let channelCount = max(channels, 1)
        var data = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let amplitude = 0.28 * Double(Int16.max)
            for frame in 0..<frameCount {
                let value = sin(2.0 * Double.pi * frequency * Double(frame) / Double(sampleRate))
                let sample = Int16((value * amplitude).rounded())
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] = sample
                }
            }
        }
        return data
    }

    static func int16Data(from buffer: AVAudioPCMBuffer) -> Data {
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let byteCount = frameLength * max(channels, 1) * MemoryLayout<Int16>.size
        if buffer.format.isInterleaved {
            let audioBuffer = buffer.audioBufferList.pointee.mBuffers
            guard let mData = audioBuffer.mData else { return Data() }
            return Data(bytes: mData, count: min(Int(audioBuffer.mDataByteSize), byteCount))
        }
        guard let channel = buffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: channel, count: frameLength * MemoryLayout<Int16>.size)
    }
}

private final class SubmitOnce: @unchecked Sendable {
    var done = false
}

enum AudioConversionError: LocalizedError {
    case invalidFormat
    case converterUnavailable
    case allocationFailed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "The session audio format is not supported."
        case .converterUnavailable:
            "The watch could not convert microphone audio."
        case .allocationFailed:
            "The watch ran out of audio buffer memory."
        case .conversionFailed:
            "Microphone audio conversion failed."
        }
    }
}
