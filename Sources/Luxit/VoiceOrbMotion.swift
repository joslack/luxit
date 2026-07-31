import CoreGraphics

enum VoiceOrbMotion {
    static let speedScale: CGFloat = 1.06
    static let rotationScale: CGFloat = 0.17
    static let currentScale: CGFloat = 0.72
    static let jitterScale: CGFloat = 0.28
    static let spatialScale: CGFloat = 1.08
    static let turbulenceScale: CGFloat = 0.38
    static let voiceResponseScale: CGFloat = 0.92
    static let voiceRippleAmplitude: CGFloat = 12
    static let voiceRippleSpatialFrequency: CGFloat = 17.5
    static let voiceRipplePhaseSpeed: CGFloat = 2.8
    static let voiceRippleOnset: CGFloat = 0.14
    static let voiceRippleFullLevel: CGFloat = 0.78
    static let baseRadius: CGFloat = 78
    static let voiceRadiusGrowth: CGFloat = 10
    static let maximumParticleEDRGain: CGFloat = 1.55
    static let processingRippleAmplitude: CGFloat = 9
    static let processingRippleExtent: CGFloat = 1.35
    static let minimumParticleRadius: CGFloat = 0.55
    static let particleMoteMinimumAspect: CGFloat = 0.86
    static let particleMoteFieldExponent: CGFloat = 0.82

    static let idleVisualFloor: CGFloat = 0.12
    static let processingLevelFloor: CGFloat = 0.48
    static let processingMotionSpeed: CGFloat = 1.4
    static let processingTransitionDuration: CGFloat = 0.72
    static let processingMinimumDwell: CGFloat = 0.32
    static let appearanceTransitionDuration: CGFloat = 0.56
    static let completionTransitionDuration: CGFloat = 0.42

    static func visibilityAlpha(_ progress: CGFloat) -> CGFloat {
        pow(clamp(progress), 1.4)
    }

    static func materializationBlend(_ progress: CGFloat) -> CGFloat {
        smoothstep(0, 1, progress)
    }

    static func materializationCondensation(
        appearance: CGFloat,
        completion: CGFloat
    ) -> CGFloat {
        materializationBlend(appearance) *
            (1 - materializationBlend(completion))
    }

    static func materializationFieldRadius(
        baseRadius: CGFloat,
        panelExtent: CGFloat
    ) -> CGFloat {
        min(baseRadius * 1.35, max(0, panelExtent / 2 - 18))
    }

    static func materializationDotScale(_ condensation: CGFloat) -> CGFloat {
        0.55 + clamp(condensation) * 0.45
    }

    static func processingBreathScale(_ pulse: CGFloat) -> CGFloat {
        1 + clamp(pulse) * 0.06
    }

    static func particleHaloWidth(
        coreRadius: CGFloat
    ) -> CGFloat {
        min(0.80, max(0.50, coreRadius * 0.25))
    }

    static func particleMoteAspect(seed: CGFloat) -> CGFloat {
        particleMoteMinimumAspect +
            smoothstep(0, 1, wrapUnit(seed)) *
            (1 - particleMoteMinimumAspect)
    }

    static func particleMoteField(radius: CGFloat) -> CGFloat {
        pow(
            max(0, 1 - smoothstep(0.06, 1, max(0, radius))),
            particleMoteFieldExponent
        )
    }

    static func particleEDRGain(
        availableHeadroom: CGFloat
    ) -> CGFloat {
        min(
            maximumParticleEDRGain,
            max(1, availableHeadroom)
        )
    }

    static func particleBaseAlpha(
        intensity: CGFloat
    ) -> CGFloat {
        0.65 + clamp(intensity) * 0.35
    }

    static func materializationAlpha(
        _ progress: CGFloat,
        seed: CGFloat
    ) -> CGFloat {
        let stagger = clamp(seed)
        return smoothstep(
            stagger * 0.14,
            0.58 + stagger * 0.18,
            progress
        )
    }

    static func advanceProcessingProgress(
        _ current: CGFloat,
        elapsed: CGFloat
    ) -> CGFloat {
        guard processingTransitionDuration > 0 else { return 1 }
        return max(
            0,
            min(1, current + elapsed / processingTransitionDuration)
        )
    }

    static func processingGeometryBlend(_ progress: CGFloat) -> CGFloat {
        smoothstep(0, 1, progress)
    }

    static func processingColorBlend(_ progress: CGFloat) -> CGFloat {
        smoothstep(0.45, 1, progress) * 0.55
    }

    static func processingRippleOffset(
        radialDistance: CGFloat,
        processingProgress: CGFloat,
        completion: CGFloat
    ) -> CGFloat {
        let processing = clamp(processingProgress)
        let waveFront = processing * processingRippleExtent
        let distance = radialDistance - waveFront
        let entrance = smoothstep(0, 0.12, processing)
        return exp(-(distance * distance) * 38) *
            processingRippleAmplitude *
            entrance *
            (1 - clamp(completion))
    }

    static func voiceRippleOffset(
        radialDistance: CGFloat,
        angle: CGFloat,
        seed: CGFloat,
        phase: CGFloat,
        level: CGFloat,
        intensity: CGFloat,
        driftScale: CGFloat
    ) -> CGFloat {
        let radius = max(0, radialDistance)
        let voice = smoothstep(
            voiceRippleOnset,
            voiceRippleFullLevel,
            level
        )
        guard voice > 0 else { return 0 }

        let angularWarp =
            sin(angle * 3 + phase * 0.34) * 0.58 +
            cos(angle * 5 - phase * 0.21) * 0.24
        let seedWarp = sin(seed + phase * 0.17) * 0.18
        let carrier = sin(
            radius * voiceRippleSpatialFrequency -
                phase * voiceRipplePhaseSpeed +
                angularWarp +
                seedWarp
        )
        let harmonic =
            sin(
                radius * voiceRippleSpatialFrequency * 0.52 -
                    phase * voiceRipplePhaseSpeed * 0.71 -
                    angularWarp * 0.65 +
                    .pi / 3
            ) * 0.16
        let crossWave =
            sin(
                radius * 11 * cos(angle - phase * 0.22) -
                    phase * 2.15 +
                    seed * 0.09
            ) * 0.24
        let amplitudeDrift =
            0.88 + sin(phase * 0.61 + angle * 2 + seed) * 0.12
        let centerEntrance = smoothstep(0.04, 0.22, radius)
        let outerRelease =
            1 - smoothstep(0.92, 1.34, radius) * 0.18
        let particleWeight =
            (0.72 + clamp(intensity) * 0.28) *
            (0.88 + clamp(driftScale / 1.74) * 0.12)

        return (carrier + harmonic + crossWave) *
            voiceRippleAmplitude *
            voice *
            centerEntrance *
            outerRelease *
            particleWeight *
            amplitudeDrift
    }

    private static func smoothstep(
        _ lower: CGFloat,
        _ upper: CGFloat,
        _ value: CGFloat
    ) -> CGFloat {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        let normalized = max(0, min(1, (value - lower) / (upper - lower)))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(0, min(1, value))
    }

    private static func wrapUnit(_ value: CGFloat) -> CGFloat {
        let wrapped = value - floor(value)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

}
