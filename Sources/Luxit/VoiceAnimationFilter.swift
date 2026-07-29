import Foundation

struct VoiceAnimationFrame {
    let level: Float
    let spectrum: [Float]
    let voiceConfidence: Float
}

/// Conditions visualization input toward human speech without changing the
/// audio written for transcription.
///
/// Static frequency weighting rejects much of HVAC rumble and high-frequency
/// hiss. A persistent, slowly adapting per-band noise estimate then subtracts
/// stationary energy while preserving changing voice/formant energy.
final class VoiceAnimationFilter {
    static let calibrationFrameCount = 8

    private var noiseEstimate: [Float] = []
    private var hasNoiseBaseline = false
    private var tonalBackground: Float = 0
    private var calibrationFramesRemaining = 0

    func beginRecording() {
        noiseEstimate = []
        hasNoiseBaseline = false
        tonalBackground = 0
        calibrationFramesRemaining = Self.calibrationFrameCount
    }

    func process(level: Float, spectrum: [Float]) -> VoiceAnimationFrame {
        guard !spectrum.isEmpty else {
            return VoiceAnimationFrame(
                level: 0,
                spectrum: [],
                voiceConfidence: 0
            )
        }
        if noiseEstimate.count != spectrum.count {
            noiseEstimate = Array(repeating: 0, count: spectrum.count)
            hasNoiseBaseline = false
        }

        let isCalibrating = calibrationFramesRemaining > 0
        let quietEnoughToLearn = level < 0.007
        let hadNoiseBaseline = hasNoiseBaseline
        var totalEnergy: Float = 0
        var voiceWeightedEnergy: Float = 0
        var residualEnergy: Float = 0
        var filtered = Array(repeating: Float.zero, count: spectrum.count)

        for index in spectrum.indices {
            let current = max(0, spectrum[index])
            let weight = Self.voiceWeight(
                at: index,
                bandCount: spectrum.count
            )
            totalEnergy += current
            voiceWeightedEnergy += current * weight

            if isCalibrating {
                // HVAC energy fluctuates even though it sounds stationary.
                // Keep the strongest observed value in each band during the
                // short materialization window so those fluctuations become
                // part of the room baseline instead of animating the orb.
                noiseEstimate[index] = hadNoiseBaseline
                    ? max(noiseEstimate[index], current)
                    : current
            } else if !hadNoiseBaseline {
                // Capture the room on the first microphone frame even when a
                // nearby fan or A/C is louder than the ordinary quiet limit.
                // The first frame remains visible below; only later stationary
                // energy is subtracted.
                noiseEstimate[index] = current
            } else if quietEnoughToLearn {
                let rate: Float =
                    current < noiseEstimate[index] ? 0.16 : 0.035
                noiseEstimate[index] +=
                    (current - noiseEstimate[index]) * rate
            } else if hasNoiseBaseline {
                // Track a falling noise floor quickly but never absorb speech
                // into the baseline during an active utterance.
                let rate: Float =
                    current < noiseEstimate[index] ? 0.08 : 0.00035
                noiseEstimate[index] +=
                    (current - noiseEstimate[index]) * rate
            }

            let residual = hadNoiseBaseline && !isCalibrating
                ? max(0, current - noiseEstimate[index] * 1.12)
                : current
            filtered[index] = residual * weight
            residualEnergy += filtered[index]
        }

        guard totalEnergy > 0.000_000_1 else {
            return VoiceAnimationFrame(
                level: 0,
                spectrum: filtered,
                voiceConfidence: 0
            )
        }
        hasNoiseBaseline = true
        if isCalibrating {
            calibrationFramesRemaining -= 1
            return VoiceAnimationFrame(
                level: 0,
                spectrum: filtered.map { _ in 0 },
                voiceConfidence: 0
            )
        }
        let voiceBandFraction = voiceWeightedEnergy / totalEnergy
        let bandConfidence = Self.clamp(
            (voiceBandFraction - 0.28) / 0.58
        )
        let residualFraction = Self.clamp(
            residualEnergy / max(voiceWeightedEnergy, 0.000_000_1)
        )
        let stationaryConfidence: Float = hasNoiseBaseline
            ? residualFraction
            : 1
        let spectralPeakShare =
            (filtered.max() ?? 0) / max(residualEnergy, 0.000_000_1)
        let tonalConfidence = Self.clamp(
            (spectralPeakShare - 0.42) / 0.30
        )
        let audibleConfidence = Self.clamp(
            (level - 0.0035) / 0.0065
        )
        let tonalTarget = tonalConfidence * audibleConfidence
        let broadSpeechLike =
            spectralPeakShare < 0.38 && bandConfidence > 0.55
        let tonalRate: Float
        if tonalTarget > tonalBackground {
            tonalRate = 0.35
        } else {
            tonalRate = broadSpeechLike ? 0.18 : 0.035
        }
        tonalBackground +=
            (tonalTarget - tonalBackground) * tonalRate

        // Phone speakers and notification sounds often produce a sustained,
        // narrow spectral peak inside the speech band. Attenuate that pattern
        // softly and retain state between frames so note changes cannot create
        // one-frame bursts of orb motion. Real speech normally spreads energy
        // across several harmonic and formant bands.
        let tonalGate = 1 - tonalBackground * 0.85
        let confidence = Self.clamp(
            bandConfidence * stationaryConfidence
        ) * tonalGate
        return VoiceAnimationFrame(
            level: level * pow(confidence, 0.68),
            spectrum: filtered.map { $0 * tonalGate },
            voiceConfidence: confidence
        )
    }

    private static func voiceWeight(
        at index: Int,
        bandCount: Int
    ) -> Float {
        guard bandCount > 1 else { return 1 }
        // The analyzer uses logarithmic bands from 90 Hz to 8 kHz.
        let minimumFrequency = 90.0
        let maximumFrequency = 8_000.0
        let ratio = pow(
            maximumFrequency / minimumFrequency,
            1 / Double(bandCount)
        )
        let frequency = minimumFrequency * pow(
            ratio,
            Double(index) + 0.5
        )
        switch frequency {
        case ..<105:
            return 0.08
        case 105..<170:
            return 0.38
        case 170..<320:
            return 0.78
        case 320..<3_400:
            return 1.0
        case 3_400..<5_200:
            return 0.68
        default:
            return 0.24
        }
    }

    private static func clamp(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
