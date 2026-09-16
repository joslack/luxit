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
        expect(VoiceOrbMotion.framesPerSecond == 60,
               "cloud animation has one bounded 60 Hz rendering cadence")
        expect(VoiceOrbMotion.frameElapsed(since: 10, now: 10 + 1.0 / 120) < 0.009,
               "high refresh animation keeps its normal frame time")
        expect(VoiceOrbMotion.frameElapsed(since: 10, now: 3610) == 1.0 / 30,
               "resuming after an hour idle advances one frame, not the full appearance")
        expect(VoiceOrbMotion.frameElapsed(since: 11, now: 10) == 0,
               "clock changes cannot reverse the materialization")
        expect(
            VoiceOrbMotion.speedScale == 1.08 &&
                VoiceOrbMotion.currentScale < 1 &&
                VoiceOrbMotion.attractorScale < 1 &&
                VoiceOrbMotion.jitterScale < 0.5 &&
                VoiceOrbMotion.spatialScale == 1.08 &&
                VoiceOrbMotion.voiceResponseScale == 1.65 &&
                VoiceOrbMotion.idleVisualFloor == 0.12 &&
                VoiceOrbMotion.baseRadius >= 100 &&
                VoiceOrbMotion.voiceRadiusGrowth >= 10,
            "the cloud retains a full resting volume with continuous independent motion"
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

        expect(VoiceOrbMotion.voiceSpeed(level: 0.6) > VoiceOrbMotion.voiceSpeed(level: 0) * 8,
               "speech rapidly accelerates independent particle paths while silence stays calm")
        expect(VoiceOrbMotion.flowSpeed(level: 0.6) > VoiceOrbMotion.flowSpeed(level: 0) * 4,
               "voice brings visible energy to the cloud's larger currents")
        expect(VoiceOrbMotion.voiceSpeed(level: -1) == VoiceOrbMotion.voiceSpeed(level: 0) &&
               VoiceOrbMotion.flowSpeed(level: 2) == VoiceOrbMotion.flowSpeed(level: 1),
               "invalid levels cannot reverse or explode motion")
        expect(VoiceOrbMotion.voiceSpeed(level: 0) == 0.45 &&
               VoiceOrbMotion.flowSpeed(level: 0) == 0.65 &&
               VoiceOrbMotion.particleJitterScale(level: 0) == VoiceOrbMotion.jitterScale,
               "added speech energy leaves the resting field unchanged")
        let mediumVoice = VoiceOrbMotion.voiceSpeed(level: 0.6)
        let mediumFlow = VoiceOrbMotion.flowSpeed(level: 0.6)
        expect(mediumVoice > 5.5 && mediumVoice < 6 && mediumFlow > 3.2 && mediumFlow < 3.5,
               "ordinary speech has a modest speed lift rather than doubling the motion")
        let mediumJitter = VoiceOrbMotion.particleJitterScale(level: 0.6)
        expect(mediumJitter > VoiceOrbMotion.jitterScale * 1.1 &&
               VoiceOrbMotion.particleJitterScale(level: 1) < VoiceOrbMotion.jitterScale * 1.2,
               "independent motion gains texture during speech with a restrained maximum")
        expect(VoiceOrbMotion.particleJitterScale(level: -1) == VoiceOrbMotion.jitterScale &&
               VoiceOrbMotion.particleJitterScale(level: 2) == VoiceOrbMotion.particleJitterScale(level: 1),
               "out-of-range levels cannot amplify particle jitter beyond its bound")
        let anchor = SIMD2<Float>(15, 0)
        var dissolved = VoiceOrbDissolution()
        dissolved.advance(anchor: anchor, pointer: .zero, seed: 1, elapsed: 1 / 60)
        expect(dissolved.amount > 0 && dissolved.amount < 0.3 && dissolved.offset.x < 1,
               "cursor entry starts dissolving without a position or opacity jump")
        for _ in 0..<60 { dissolved.advance(anchor: anchor, pointer: .zero, seed: 1, elapsed: 1 / 60) }
        expect(dissolved.amount > 0.99 && dissolved.offset.x > 10,
               "a stationary cursor holds the particles dissolved and displaced")
        let held = dissolved
        dissolved.advance(anchor: anchor, pointer: nil, seed: 1, elapsed: 1 / 60)
        expect(dissolved.amount > 0.9 && dissolved.offset.x > held.offset.x * 0.95,
               "leaving the cloud preserves momentum and begins a gradual reformation")
        for _ in 0..<180 { dissolved.advance(anchor: anchor, pointer: nil, seed: 1, elapsed: 1 / 60) }
        expect(dissolved.amount < 0.001 && abs(dissolved.offset.x) < 0.001,
               "particles fully reform at their moving anchors without permanent drift")
        var results: [VoiceOrbDissolution] = []
        for hz in [30, 60, 120] {
            var state = VoiceOrbDissolution()
            for _ in 0..<(hz / 2) { state.advance(anchor: .zero, pointer: .zero, seed: 1, elapsed: 1 / Float(hz)) }
            expect(state.offset.x.isFinite && state.offset.y.isFinite && state.amount > 0.99,
                   "exact cursor overlap stays finite at every supported cadence")
            results.append(state)
        }
        expect(abs(results[0].offset.x - results[2].offset.x) < 0.3,
               "the physical response is consistent across display refresh rates")
        var resumed = held
        var bounded = held
        resumed.advance(anchor: anchor, pointer: nil, seed: 1, elapsed: 3600)
        bounded.advance(anchor: anchor, pointer: nil, seed: 1, elapsed: 1 / 30)
        expect(resumed.offset == bounded.offset && resumed.amount == bounded.amount,
               "idle recovery cannot make the particle simulation explode")
        print("VoiceOrbConfigurationTests passed")
    }
}
