import CoreGraphics

enum VoiceOrbMotion {
    static let speedScale: CGFloat = 1.08
    static let currentScale: CGFloat = 0.86
    static let jitterScale: CGFloat = 0.58
    static let spatialScale: CGFloat = 1.08
    static let voiceResponseScale: CGFloat = 1.65

    static let idleVisualFloor: CGFloat = 0.12
    static let processingLevelFloor: CGFloat = 0.48
    static let processingMotionSpeed: CGFloat = 1.4
    static let processingTransitionDuration: CGFloat = 0.72

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
}
