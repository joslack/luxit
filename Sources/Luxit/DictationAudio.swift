import AVFoundation
import Foundation

struct RecordedAudio {
    let url: URL
    let duration: TimeInterval
    let channel: Int
    let peakLevel: Float
    let voicedSeconds: TimeInterval

    var isEmptyOrTooShort: Bool {
        // The local transcription backend runs speech detection. An additional
        // volume gate here discards quiet voices before that detector sees them.
        duration < 0.35 || !peakLevel.isFinite || peakLevel <= 0
    }
}

/// Dictation can receive the built-in microphone's individual channels during
/// calls. Inspect every channel, but keep the captured file untouched. Choose
/// one channel for the entire utterance so conversion neither cancels channels
/// against each other nor relies on an unspecified multichannel downmix.
struct DictationAudioMetrics {
    private struct Channel {
        var energy: Double = 0
        var peakLevel: Float = 0
        var voicedSeconds: TimeInterval = 0
    }

    private var channels: [Channel] = []

    var selectedChannel: Int? {
        guard !channels.isEmpty else { return nil }
        return channels.indices.dropFirst().reduce(0) { best, candidate in
            channels[candidate].energy > channels[best].energy ? candidate : best
        }
    }

    var peakLevel: Float { selectedChannel.map { channels[$0].peakLevel } ?? 0 }
    var voicedSeconds: TimeInterval { selectedChannel.map { channels[$0].voicedSeconds } ?? 0 }

    /// Returns the loudest channel in this callback for visualization. The
    /// saved utterance's channel is selected by total energy when it finishes.
    mutating func append(_ buffer: AVAudioPCMBuffer) -> Int? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }
        if channels.isEmpty { channels = Array(repeating: Channel(), count: channelCount) }
        // An engine reconfiguration ends the current file rather than mixing
        // different channel layouts into the same recording.
        guard channels.count == channelCount else { return nil }
        var loudest = 0
        var loudestEnergy: Double = -1
        for channel in 0..<channelCount {
            var energy: Double = 0
            for frame in 0..<count {
                let sample = Double(data[channel][frame * buffer.stride])
                if sample.isFinite { energy += sample * sample }
            }
            let rms = Float(sqrt(energy / Double(count)))
            channels[channel].energy += energy / buffer.format.sampleRate
            channels[channel].peakLevel = max(channels[channel].peakLevel, rms)
            if rms >= 0.006 {
                channels[channel].voicedSeconds += Double(count) / buffer.format.sampleRate
            }
            if energy > loudestEnergy { loudest = channel; loudestEnergy = energy }
        }
        return loudest
    }
}

enum DictationAudioConversion {
    static func arguments(input: URL, output: URL, channel: Int) -> [String] {
        ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
         "-m", String(channel), input.path, output.path]
    }
}
