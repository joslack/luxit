import CoreGraphics
import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VoiceOrbConfigurationTests {
    static func main() {
        expect(
            VoiceOrbMotion.speedScale == 1.08 &&
                VoiceOrbMotion.currentScale == 0.86 &&
                VoiceOrbMotion.jitterScale == 0.58 &&
                VoiceOrbMotion.spatialScale == 1.08 &&
                VoiceOrbMotion.voiceResponseScale == 1.65 &&
                VoiceOrbMotion.idleVisualFloor == 0.12 &&
                VoiceOrbMotion.particleContrastRimWidth == 0.45 &&
                VoiceOrbMotion.particleContrastRimOpacity == 0.25,
            "the sole orb motion remains the attractor behavior"
        )
        let firstProcessingFrame =
            VoiceOrbMotion.advanceProcessingProgress(0, elapsed: 0.1)
        let laterProcessingFrame =
            VoiceOrbMotion.advanceProcessingProgress(
                firstProcessingFrame,
                elapsed: 0.2
            )
        expect(
            firstProcessingFrame > 0 &&
                laterProcessingFrame > firstProcessingFrame &&
                laterProcessingFrame < 1,
            "processing transition advances monotonically without jumping"
        )
        expect(
            VoiceOrbMotion.processingColorBlend(firstProcessingFrame) == 0,
            "the recording-to-processing handoff stays white initially"
        )
        expect(
            VoiceOrbMotion.processingColorBlend(1) == 0.55,
            "the processing color settles at a restrained warm tint"
        )
        expect(
            VoiceOrbMotion.processingMinimumDwell == 0.32 &&
                VoiceOrbMotion.appearanceTransitionDuration == 0.56 &&
                VoiceOrbMotion.completionTransitionDuration == 0.42,
            "processing and materialization keep deliberate timing"
        )
        expect(
            VoiceOrbMotion.visibilityAlpha(0) == 0 &&
                VoiceOrbMotion.visibilityAlpha(1) == 1,
            "dematerialization preserves its opacity endpoints"
        )
        let halfwayAlpha = VoiceOrbMotion.visibilityAlpha(0.5)
        expect(
            halfwayAlpha > 0 && halfwayAlpha < 1,
            "dematerialization fades progressively as the field releases"
        )
        expect(
            VoiceOrbMotion.materializationBlend(0) == 0 &&
                VoiceOrbMotion.materializationBlend(1) == 1,
            "the loose field condenses fully and can reverse cleanly"
        )
        let partialCondensation =
            VoiceOrbMotion.materializationCondensation(
                appearance: 0.4,
                completion: 0
            )
        expect(
            VoiceOrbMotion.materializationCondensation(
                appearance: 0.4,
                completion: 0.5
            ) < partialCondensation &&
                VoiceOrbMotion.materializationCondensation(
                    appearance: 0.4,
                    completion: 1
                ) == 0,
            "completion only releases the current cloud outward"
        )
        expect(
            VoiceOrbMotion.materializationFieldRadius(
                baseRadius: 70,
                panelExtent: 280
            ) == 94.5 &&
                VoiceOrbMotion.materializationFieldRadius(
                    baseRadius: 200,
                    panelExtent: 280
                ) == 122,
            "the loose field expands around the orb without clipping"
        )
        expect(
            VoiceOrbMotion.materializationDotScale(0) == 0.55 &&
                VoiceOrbMotion.materializationDotScale(1) == 1,
            "particles grow while materializing and stay full-size afterward"
        )
        expect(
            VoiceOrbMotion.processingBreathScale(0) == 1 &&
                VoiceOrbMotion.processingBreathScale(1) == 1.06,
            "processing begins at full volume instead of contracting"
        )
        expect(
            VoiceOrbMotion.materializationAlpha(0, seed: 0.5) == 0 &&
                VoiceOrbMotion.materializationAlpha(1, seed: 0.5) == 1,
            "particles materialize with deterministic staggered opacity"
        )
        expect(
            VoiceOrbMotion.baseRadius == 70 &&
                VoiceOrbMotion.voiceRadiusGrowth == 15,
            "the orb keeps its enlarged shared visual footprint"
        )

        let visibleFrame = CGRect(x: 100, y: 40, width: 1_200, height: 800)
        let frame = VoiceOrbLayout.frame(in: visibleFrame)
        expect(frame.size == VoiceOrbLayout.size, "orb uses its fixed panel size")
        expect(frame.maxX == visibleFrame.maxX - VoiceOrbLayout.inset,
               "orb is inset from the right edge")
        expect(frame.minY == visibleFrame.minY + VoiceOrbLayout.inset,
               "orb is inset from the bottom edge")

        print("VoiceOrbConfigurationTests passed")
    }
}
