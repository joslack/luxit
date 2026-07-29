import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VoiceAnimationFilterTests {
    static func main() {
        let lowRumble = spectrum(peakBand: 0, amplitude: 1)
        let voiceFormant = spectrum(peakBand: 11, amplitude: 1)

        let rumbleFilter = VoiceAnimationFilter()
        let rumble = rumbleFilter.process(
            level: 0.02,
            spectrum: lowRumble
        )
        let voiceFilter = VoiceAnimationFilter()
        let voice = voiceFilter.process(
            level: 0.02,
            spectrum: voiceFormant
        )
        expect(
            voice.level > rumble.level * 4,
            "voice-band energy should drive animation more than low rumble"
        )

        let steadyFilter = VoiceAnimationFilter()
        let firstBackground = steadyFilter.process(
            level: 0.005,
            spectrum: voiceFormant
        )
        let repeatedBackground = steadyFilter.process(
            level: 0.005,
            spectrum: voiceFormant
        )
        expect(
            repeatedBackground.level <= firstBackground.level,
            "learned stationary background should not grow the animation"
        )

        let voiceOverBackground = voiceFormant.enumerated().map {
            $0.element + ($0.offset == 14 ? 1.4 : 0)
        }
        let foreground = steadyFilter.process(
            level: 0.025,
            spectrum: voiceOverBackground
        )
        expect(
            foreground.level > repeatedBackground.level,
            "new voice energy should survive learned noise subtraction"
        )

        let musicFilter = VoiceAnimationFilter()
        let holdTone = spectrum(peakBand: 12, amplitude: 1)
        let firstHoldFrame = musicFilter.process(
            level: 0.012,
            spectrum: holdTone
        )
        var settledHoldFrame = firstHoldFrame
        for _ in 0..<11 {
            settledHoldFrame = musicFilter.process(
                level: 0.012,
                spectrum: holdTone
            )
        }
        expect(
            settledHoldFrame.level < firstHoldFrame.level * 0.5,
            "sustained tonal background should fade out of the animation"
        )

        let speechFilter = VoiceAnimationFilter()
        let quietSpeech = multiFormantSpectrum(
            bands: [7, 11, 15],
            amplitude: 0.7
        )
        let quietVoice = speechFilter.process(
            level: 0.008,
            spectrum: quietSpeech
        )
        expect(
            quietVoice.level > settledHoldFrame.level,
            "quiet multi-formant speech should remain more visible than hold music"
        )

        let voiceOverHold = holdTone.enumerated().map { index, energy in
            energy + (quietSpeech[index] * 1.2)
        }
        var recoveredVoice = settledHoldFrame
        for _ in 0..<5 {
            recoveredVoice = musicFilter.process(
                level: 0.02,
                spectrum: voiceOverHold
            )
        }
        expect(
            recoveredVoice.level > settledHoldFrame.level * 2,
            "broad nearby speech should reopen the gate over hold music"
        )

        let hvacFilter = VoiceAnimationFilter()
        hvacFilter.beginRecording()
        _ = hvacFilter.process(
            level: 0,
            spectrum: Array(repeating: 0, count: 23)
        )
        let hvacSpectrum = multiFormantSpectrum(
            bands: [2, 3, 4, 8, 12, 17, 20],
            amplitude: 0.7
        )
        for frame in 0..<VoiceAnimationFilter.calibrationFrameCount {
            let fluctuation = Float(frame % 3) * 0.08
            let calibrationSpectrum = hvacSpectrum.map {
                $0 * (1 + fluctuation)
            }
            let calibrationFrame = hvacFilter.process(
                level: 0.018 + fluctuation * 0.01,
                spectrum: calibrationSpectrum
            )
            expect(
                calibrationFrame.level == 0,
                "ambient calibration should stay inside materialization"
            )
        }
        let settledHVACFrame = hvacFilter.process(
            level: 0.018,
            spectrum: hvacSpectrum
        )
        expect(
            settledHVACFrame.level == 0,
            "a fluctuating A/C should remain below its calibrated band peaks"
        )

        let voiceOverHVAC = hvacSpectrum.enumerated().map { index, energy in
            energy + ([7, 11, 15].contains(index) ? 1.4 : 0)
        }
        let voiceOverHVACFrame = hvacFilter.process(
            level: 0.028,
            spectrum: voiceOverHVAC
        )
        expect(
            voiceOverHVACFrame.level > settledHVACFrame.level,
            "speech above the calibrated A/C should still animate the orb"
        )
        print("VoiceAnimationFilterTests passed")
    }

    private static func spectrum(
        peakBand: Int,
        amplitude: Float
    ) -> [Float] {
        (0..<23).map { $0 == peakBand ? amplitude : 0 }
    }

    private static func multiFormantSpectrum(
        bands: Set<Int>,
        amplitude: Float
    ) -> [Float] {
        (0..<23).map { bands.contains($0) ? amplitude : 0 }
    }
}
