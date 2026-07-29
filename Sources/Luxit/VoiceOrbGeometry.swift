import CoreGraphics
import Foundation

struct VoiceOrbPoint: Equatable {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let intensity: CGFloat
    let velocity: CGFloat
    let flowPhase: CGFloat
    let flowPhaseY: CGFloat
    let driftScale: CGFloat
}

/// Produces an amorphous but deterministic point cloud from a spectrum.
///
/// There is deliberately no clock or random state in this mapping. The same
/// spectrum produces the same cloud, while nearby spectra produce nearby
/// shapes. That makes the motion descriptive of the sound rather than merely
/// decorative.
enum VoiceOrbGeometry {
    private static let goldenAngle = CGFloat.pi * (3 - sqrt(5))
    static let defaultPointCount = 1024

    static func points(
        spectrum: [CGFloat],
        level: CGFloat,
        count: Int = defaultPointCount
    ) -> [VoiceOrbPoint] {
        guard count > 0 else { return [] }
        let profile = spectrum.isEmpty ? [CGFloat.zero] : spectrum.map {
            max(0, min(1, $0))
        }
        let voice = max(0, min(1, level))
        let energyTotal = max(0.0001, profile.reduce(0, +))
        let centroid = profile.enumerated().reduce(CGFloat.zero) {
            $0 + CGFloat($1.offset) * $1.element
        } / energyTotal / CGFloat(max(1, profile.count - 1))

        return (0..<count).map { index in
            let fill = sqrt((CGFloat(index) + 0.5) / CGFloat(count))
            let angleJitter = (unitHash(index, salt: 17) - 0.5) * 0.23
            let angle = CGFloat(index) * goldenAngle + angleJitter
            // Frequency membership is independent of spatial angle. Each band
            // therefore illuminates a stable constellation scattered through
            // every quadrant instead of moving one contiguous wedge.
            let frequencyCoordinate = unitHash(index, salt: 313)
            let bandPosition = frequencyCoordinate * CGFloat(profile.count)
            let lowerBand = min(
                profile.count - 1,
                Int(floor(bandPosition))
            )
            let upperBand = (lowerBand + 1) % profile.count
            let fraction = bandPosition - floor(bandPosition)
            let localEnergy =
                profile[lowerBand] * (1 - fraction) +
                profile[upperBand] * fraction
            let previousEnergy = profile[
                (lowerBand + profile.count - 1) % profile.count
            ]
            let nextEnergy = profile[
                (upperBand + 1) % profile.count
            ]
            let spectralEdge = min(
                1,
                abs(nextEnergy - previousEnergy) * 1.8
            )
            let grain = unitHash(index, salt: 71) - 0.5
            let radialCharacter =
                0.92 +
                localEnergy * 0.25 +
                spectralEdge * 0.10 +
                grain * (0.040 + localEnergy * 0.050)
            let horizontalCharacter = 0.94 + (centroid - 0.5) * 0.10
            let verticalCharacter = 0.98 - (centroid - 0.5) * 0.08
            let radius = fill * radialCharacter
            let spectralWarp = localEnergy * 0.055
            let x =
                cos(angle) * radius * horizontalCharacter +
                (unitHash(index, salt: 113) - 0.5) * spectralWarp
            let y =
                sin(angle) * radius * verticalCharacter +
                (unitHash(index, salt: 197) - 0.5) * spectralWarp
            let pointIntensity = max(
                0,
                min(
                    1,
                    (0.20 + localEnergy * 0.80) *
                    (0.30 + voice * 0.70)
                )
            )
            let pointRadius = particleRadius(
                sizeSeed: unitHash(index, salt: 251),
                sizeRole: unitHash(index, salt: 613),
                localEnergy: localEnergy,
                voice: voice
            )
            return VoiceOrbPoint(
                x: x,
                y: y,
                radius: pointRadius,
                intensity: pointIntensity,
                velocity: 0.42 + unitHash(index, salt: 401) * 2.25,
                flowPhase: unitHash(index, salt: 457) * 2 * .pi,
                flowPhaseY: unitHash(index, salt: 503) * 2 * .pi,
                driftScale: 0.62 + unitHash(index, salt: 557) * 1.12
            )
        }
    }

    static func particleRadius(
        sizeSeed: CGFloat,
        sizeRole: CGFloat,
        localEnergy: CGFloat,
        voice: CGFloat
    ) -> CGFloat {
        let seed = max(0, min(1, sizeSeed))
        let baseline: CGFloat
        if seed < 0.18 {
            // Keep a deliberate dust-like tail even as the typical grain
            // becomes more substantial.
            baseline = 0.30 + seed / 0.18 * 0.25
        } else {
            let body = (seed - 0.18) / 0.82
            baseline = 0.55 + pow(body, 0.78) * 0.76
        }

        let role = max(0, min(1, sizeRole))
        let largeGrainScale: CGFloat
        if role > 0.88 {
            largeGrainScale =
                1.65 + (role - 0.88) / 0.12 * 0.75
        } else {
            largeGrainScale = 1
        }
        return (
            baseline +
            max(0, min(1, localEnergy)) * 0.62 +
            max(0, min(1, voice)) * 0.16
        ) * largeGrainScale
    }

    /// Smooth deterministic noise for independent particle motion.
    ///
    /// Each point and channel follows a different path, but nearby times
    /// interpolate rather than jumping. Callers control whether it moves at
    /// all by advancing `time` from actual audio callbacks.
    static func motionNoise(
        point index: Int,
        time: CGFloat,
        channel: Int
    ) -> CGFloat {
        let lowerStep = floor(time)
        let fraction = time - lowerStep
        let eased = fraction * fraction * (3 - 2 * fraction)
        let lower = temporalHash(
            index: index,
            step: Int64(lowerStep),
            channel: channel
        )
        let upper = temporalHash(
            index: index,
            step: Int64(lowerStep) + 1,
            channel: channel
        )
        return (lower * (1 - eased) + upper * eased) * 2 - 1
    }

    private static func positiveUnit(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func unitHash(_ index: Int, salt: UInt64) -> CGFloat {
        var value = UInt64(truncatingIfNeeded: index) &+ salt
        value ^= value >> 30
        value &*= 0xbf58_476d_1ce4_e5b9
        value ^= value >> 27
        value &*= 0x94d0_49bb_1331_11eb
        value ^= value >> 31
        return CGFloat(value & 0x00ff_ffff) / CGFloat(0x00ff_ffff)
    }

    private static func temporalHash(
        index: Int,
        step: Int64,
        channel: Int
    ) -> CGFloat {
        var value = UInt64(truncatingIfNeeded: index)
        value &*= 0x9e37_79b9_7f4a_7c15
        value ^= UInt64(bitPattern: step) &* 0xbf58_476d_1ce4_e5b9
        value ^= UInt64(truncatingIfNeeded: channel) &*
            0x94d0_49bb_1331_11eb
        value ^= value >> 30
        value &*= 0xbf58_476d_1ce4_e5b9
        value ^= value >> 27
        value &*= 0x94d0_49bb_1331_11eb
        value ^= value >> 31
        return CGFloat(value & 0x00ff_ffff) / CGFloat(0x00ff_ffff)
    }
}
