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
        print("VoiceAnimationFilterTests passed")
    }

    private static func spectrum(
        peakBand: Int,
        amplitude: Float
    ) -> [Float] {
        (0..<23).map { $0 == peakBand ? amplitude : 0 }
    }
}
