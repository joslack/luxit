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
        _ = hvacFilter.process(
            level: 0,
            spectrum: Array(repeating: 0, count: 23)
        )
        let hvacSpectrum = multiFormantSpectrum(
            bands: [2, 3, 4, 8, 12, 17, 20],
            amplitude: 0.7
        )
        let firstHVACFrame = hvacFilter.process(
            level: 0.018,
            spectrum: hvacSpectrum
        )
        let settledHVACFrame = hvacFilter.process(
            level: 0.018,
            spectrum: hvacSpectrum
        )
        expect(
            settledHVACFrame.level < firstHVACFrame.level * 0.2,
            "a loud stationary A/C should become the recording noise baseline"
        )

        hvacFilter.reset()
        let recapturedHVACFrame = hvacFilter.process(
            level: 0.018,
            spectrum: hvacSpectrum
        )
        expect(
            recapturedHVACFrame.level > settledHVACFrame.level,
            "a new recording should recapture the current room baseline"
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
