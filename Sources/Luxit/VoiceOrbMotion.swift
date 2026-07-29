import CoreGraphics

enum VoiceOrbMotion {
    static let speedScale: CGFloat = 1.08
    static let currentScale: CGFloat = 0.86
    static let jitterScale: CGFloat = 0.58
    static let spatialScale: CGFloat = 1.08
    static let voiceResponseScale: CGFloat = 1.65
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
