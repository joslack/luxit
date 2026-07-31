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
            VoiceOrbMotion.speedScale == 1.06 &&
                VoiceOrbMotion.rotationScale == 0.17 &&
                VoiceOrbMotion.currentScale == 0.72 &&
                VoiceOrbMotion.jitterScale == 0.28 &&
                VoiceOrbMotion.spatialScale == 1.08 &&
                VoiceOrbMotion.turbulenceScale == 0.38 &&
                VoiceOrbMotion.voiceResponseScale == 0.92 &&
                VoiceOrbMotion.idleVisualFloor == 0.12 &&
                VoiceOrbMotion.baseRadius == 78 &&
                VoiceOrbMotion.voiceRadiusGrowth == 10,
            "the ripple study keeps a calm underlying particle current"
        )
        let quietRipple = VoiceOrbMotion.voiceRippleOffset(
            radialDistance: 0.58,
            angle: 0.9,
            seed: 2.1,
            phase: 0.7,
            level: VoiceOrbMotion.idleVisualFloor,
            intensity: 0.8,
            driftScale: 1
        )
        let speakingRipple = VoiceOrbMotion.voiceRippleOffset(
            radialDistance: 0.58,
            angle: 0.9,
            seed: 2.1,
            phase: 0.7,
            level: 0.8,
            intensity: 0.8,
            driftScale: 1
        )
        let repeatedRipple = VoiceOrbMotion.voiceRippleOffset(
            radialDistance: 0.58,
            angle: 0.9,
            seed: 2.1,
            phase: 0.7,
            level: 0.8,
            intensity: 0.8,
            driftScale: 1
        )
        let neighboringRipple = VoiceOrbMotion.voiceRippleOffset(
            radialDistance: 0.72,
            angle: 1.2,
            seed: 3.4,
            phase: 0.7,
            level: 0.8,
            intensity: 0.8,
            driftScale: 1
        )
        expect(
            quietRipple == 0 &&
                speakingRipple == repeatedRipple &&
                speakingRipple != neighboringRipple &&
                abs(speakingRipple) <=
                    VoiceOrbMotion.voiceRippleAmplitude * 1.55,
            "speech launches bounded organic waves through the cloud"
        )
        expect(
            VoiceOrbMotion.minimumParticleRadius == 0.55 &&
                VoiceOrbMotion.particleHaloWidth(
                coreRadius: 0.2
            ) == 0.50 &&
                VoiceOrbMotion.particleHaloWidth(
                    coreRadius: 10
                ) == 0.80,
            "particles retain enough area for a soft halo"
        )
        let compressedMote =
            VoiceOrbMotion.particleMoteAspect(seed: 0)
        let roundMote =
            VoiceOrbMotion.particleMoteAspect(seed: 0.999999)
        expect(
            compressedMote == 0.86 &&
                roundMote > 0.999 &&
                roundMote <= 1,
            "stable aspect variation keeps motes subtly irregular"
        )
        let centerField =
            VoiceOrbMotion.particleMoteField(radius: 0)
        let middleField =
            VoiceOrbMotion.particleMoteField(radius: 0.5)
        let outerField =
            VoiceOrbMotion.particleMoteField(radius: 1)
        expect(
            centerField == 1 &&
                middleField > outerField &&
                middleField < centerField &&
                outerField == 0,
            "each mote is one monotonic field without visible color bands"
        )
        expect(
            VoiceOrbMotion.particleEDRGain(
                availableHeadroom: 0.5
            ) == 1 &&
                VoiceOrbMotion.particleEDRGain(
                    availableHeadroom: 1
                ) == 1 &&
                VoiceOrbMotion.particleEDRGain(
                    availableHeadroom: 3
                ) == 1.55,
            "the checkpoint dot color keeps its bright display headroom"
        )
        expect(
            VoiceOrbMotion.particleBaseAlpha(intensity: 0) == 0.65 &&
                VoiceOrbMotion.particleBaseAlpha(intensity: 1) == 1 &&
                VoiceOrbMotion.particleBaseAlpha(intensity: 2) == 1,
            "the cloud stays bright while retaining intensity variation"
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
            VoiceOrbMotion.processingColorBlend(firstProcessingFrame) == 0 &&
                VoiceOrbMotion.processingColorBlend(1) == 0.55,
            "processing restores the checkpoint's restrained warm color"
        )
        expect(
            VoiceOrbMotion.processingRippleOffset(
                radialDistance: 0.675,
                processingProgress: 0.5,
                completion: 0
            ) == VoiceOrbMotion.processingRippleAmplitude &&
                VoiceOrbMotion.processingRippleOffset(
                    radialDistance: 0.675,
                    processingProgress: 0.5,
                    completion: 1
                ) == 0 &&
                VoiceOrbMotion.processingRippleOffset(
                    radialDistance: 0,
                    processingProgress: 0,
                    completion: 0
                ) == 0,
            "processing sends one radial wave through the cloud before release"
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
