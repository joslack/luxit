import CoreGraphics

enum VoiceOrbMotion {
    static let speedScale: CGFloat = 1.08
    static let currentScale: CGFloat = 0.86
    static let jitterScale: CGFloat = 0.58
    static let spatialScale: CGFloat = 1.08
    static let voiceResponseScale: CGFloat = 1.65
    static let baseRadius: CGFloat = 70
    static let voiceRadiusGrowth: CGFloat = 15
    static let cloudUnderlayCenterOpacity: CGFloat = 0.28
    static let cloudUnderlayRadiusMultiplier: CGFloat = 1.32

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

    static func particleLuminance(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGFloat {
        clamp(red) * 0.2126 +
            clamp(green) * 0.7152 +
            clamp(blue) * 0.0722
    }

    static func particleContrastRimWidth(
        coreRadius: CGFloat
    ) -> CGFloat {
        min(0.8, max(0.65, coreRadius * 0.22))
    }

    static func particleContrastRimOpacity(
        coreLuminance: CGFloat
    ) -> CGFloat {
        0.20 + smoothstep(0.45, 0.82, coreLuminance) * 0.28
    }

    static func particleContrastRimWhite(
        coreLuminance: CGFloat
    ) -> CGFloat {
        1 - smoothstep(0.45, 0.82, coreLuminance) * 0.93
    }

    static func cloudUnderlayRadius(
        baseRadius: CGFloat,
        panelExtent: CGFloat
    ) -> CGFloat {
        min(
            baseRadius * cloudUnderlayRadiusMultiplier,
            max(0, panelExtent * 0.46)
        )
    }

    static func cloudUnderlayOpacity(
        appearance: CGFloat,
        completion: CGFloat
    ) -> CGFloat {
        cloudUnderlayCenterOpacity *
            materializationBlend(appearance) *
            visibilityAlpha(1 - clamp(completion))
    }

    static func cloudUnderlayAlpha(
        normalizedDistance: CGFloat,
        appearance: CGFloat,
        completion: CGFloat
    ) -> CGFloat {
        let distance = clamp(normalizedDistance)
        return cloudUnderlayOpacity(
            appearance: appearance,
            completion: completion
        ) * pow(1 - distance * distance, 1.15)
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
}
