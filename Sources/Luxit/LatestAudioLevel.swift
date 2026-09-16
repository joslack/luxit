import Foundation

/// Visualization only: producers replace the pending sample instead of adding
/// work to the UI queue. Recorded audio never passes through this mailbox.
final class LatestAudioLevel {
    struct Sample: Equatable {
        let level: Float
        let spectrum: [Float]
        var voiceProbability: Float? = nil
    }

    private let lock = NSLock()
    private var pending: Sample?

    func store(level: Float, spectrum: [Float] = [], voiceProbability: Float? = nil) {
        lock.lock()
        pending = Sample(level: level, spectrum: spectrum, voiceProbability: voiceProbability)
        lock.unlock()
    }

    func take() -> Sample? {
        lock.lock()
        defer { lock.unlock() }
        let sample = pending
        pending = nil
        return sample
    }
}

/// Mic and Mac have independent callback clocks. Keep the active speaker from
/// being overwritten by silence on the other track, and expire a stopped track.
final class CombinedVoiceLevels {
    private let lock = NSLock()
    private var sources: [Int: (LatestAudioLevel.Sample, TimeInterval)] = [:]

    func reset() {
        lock.lock(); defer { lock.unlock() }
        sources.removeAll()
    }

    func update(source: Int, level: Float, spectrum: [Float], probability: Float?,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LatestAudioLevel.Sample {
        lock.lock(); defer { lock.unlock() }
        let current = LatestAudioLevel.Sample(level: level, spectrum: spectrum, voiceProbability: probability)
        sources[source] = (current, now)
        sources = sources.filter { now - $0.value.1 < 0.20 }
        return sources.values.map { $0.0 }.max {
            score($0) < score($1)
        } ?? current
    }

    private func score(_ sample: LatestAudioLevel.Sample) -> Float {
        let confidence = sample.voiceProbability ?? 1
        return confidence >= 0.22 ? confidence + min(0.1, max(0, sample.level)) : 0
    }
}
