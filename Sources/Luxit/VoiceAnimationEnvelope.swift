import Foundation

/// Audio arrives in device-sized chunks; animation advances on every display
/// frame. Time-based envelopes keep syllables fluid at any callback cadence.
struct VoiceAnimationEnvelope {
    private(set) var level: Float = 0
    private(set) var spectrum = [Float](repeating: 0, count: 23)
    private var targetLevel: Float = 0
    private var targetSpectrum = [Float](repeating: 0, count: 23)
    private var sampleAge: TimeInterval = 0

    mutating func accept(_ frame: VoiceAnimationFrame) {
        targetLevel = VoiceAnimationFilter.visualResponse(for: frame)
        let strongest = frame.spectrum.max() ?? 0
        for i in targetSpectrum.indices {
            let relative = strongest > 0 && frame.spectrum.indices.contains(i)
                ? max(0, min(1, frame.spectrum[i] / strongest)) : 0
            targetSpectrum[i] = targetLevel * pow(relative, 0.55)
        }
        sampleAge = 0
    }

    mutating func advance(elapsed: TimeInterval) {
        guard elapsed.isFinite, elapsed > 0 else { return }
        sampleAge += elapsed
        if sampleAge > 0.20 {
            targetLevel = 0
            targetSpectrum = targetSpectrum.map { _ in 0 }
        }
        level = Self.follow(level, toward: targetLevel, elapsed: elapsed,
                            attack: 0.018, release: 0.12)
        for i in spectrum.indices {
            spectrum[i] = Self.follow(spectrum[i], toward: targetSpectrum[i], elapsed: elapsed,
                                      attack: 0.03, release: 0.16)
        }
    }

    private static func follow(_ value: Float, toward target: Float,
                               elapsed: TimeInterval, attack: Double, release: Double) -> Float {
        let amount = Float(1 - exp(-elapsed / (target > value ? attack : release)))
        return value + (target - value) * amount
    }
}
