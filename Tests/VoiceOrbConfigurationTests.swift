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
                VoiceOrbMotion.idleVisualFloor == 0.12,
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
