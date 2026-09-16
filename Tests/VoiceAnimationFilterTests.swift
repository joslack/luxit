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
        let mailbox = LatestAudioLevel()
        for index in 0..<10_000 {
            mailbox.store(level: Float(index), spectrum: [Float(index)])
        }
        expect(mailbox.take() == LatestAudioLevel.Sample(level: 9_999, spectrum: [9_999]),
               "a stalled UI receives the freshest level instead of replaying a backlog")
        expect(mailbox.take() == nil, "each visualization sample is consumed only once")
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            mailbox.store(level: Float(index), spectrum: [Float(index)])
            if let sample = mailbox.take() {
                expect(sample.spectrum == [sample.level], "audio level and spectrum remain an atomic pair")
            }
        }

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
            let calibrationSpectrum = hvacSpectrum.enumerated().map {
                index, energy in
                let earlyVoice: Float =
                    frame == VoiceAnimationFilter.calibrationFrameCount - 1 &&
                    [7, 11, 15].contains(index)
                        ? 1.4
                        : 0
                return energy * (1 + fluctuation) + earlyVoice
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
        expect(
            VoiceAnimationFilter.visualResponse(
                for: settledHVACFrame.level
            ) == 0 &&
                VoiceAnimationFilter.visualResponse(
                    for: voiceOverHVACFrame.level
                ) > 0.2,
            "post-gate mapping should boost voice without reviving HVAC"
        )
        expect(
            VoiceAnimationFilter.visualResponse(for: 0.0009) == 0 &&
                VoiceAnimationFilter.visualResponse(for: 0.028) == 1,
            "visual voice response should preserve its silent and full endpoints"
        )
        let detected = VoiceAnimationFilter()
        detected.beginRecording()
        let immediateSpeech = detected.process(level: 0.025, spectrum: quietSpeech, voiceProbability: 0.95)
        expect(immediateSpeech.level > 0.02, "detected speech is not swallowed by startup calibration")
        var heldSpeech = immediateSpeech
        for _ in 0..<90 {
            heldSpeech = detected.process(level: 0.025, spectrum: quietSpeech, voiceProbability: 0.95)
        }
        expect(heldSpeech.level > immediateSpeech.level * 0.95, "sustained speech is never learned as stationary noise")
        let loudNoise = detected.process(level: 0.25, spectrum: hvacSpectrum, voiceProbability: 0.05)
        expect(loudNoise.level == 0, "loud non-speech cannot drive the voice envelope")

        let softVoiceFilter = VoiceAnimationFilter()
        softVoiceFilter.beginRecording()
        let softVoice = softVoiceFilter.process(level: 0.003, spectrum: quietSpeech, voiceProbability: 0.95)
        let softResponse = VoiceAnimationFilter.visualResponse(for: softVoice.level)
        expect(softResponse > 0.27 && softResponse < 0.5,
               "quiet accepted syllables visibly animate without looking like a shout")
        expect(VoiceAnimationFilter.visualResponse(for: loudNoise.level) == 0,
               "greater speech sensitivity never revives rejected background noise")
        expect(VoiceAnimationFilter.visualResponse(for: 0.006) > 0.44 &&
               VoiceAnimationFilter.visualResponse(for: 0.012) > 0.64,
               "ordinary voice has stronger movement while retaining volume contrast")

        for rms: Float in [0.0002, 0.0008, 0.003, 0.012] {
            let soft = softVoiceFilter.process(level: rms, spectrum: quietSpeech, voiceProbability: 0.95)
            expect(VoiceAnimationFilter.visualResponse(for: soft) >= 0.74,
                   "confident speech has lively motion even below the room-level estimate")
        }
        let rejected = softVoiceFilter.process(level: 0.1, spectrum: hvacSpectrum, voiceProbability: 0.05)
        expect(VoiceAnimationFilter.visualResponse(for: rejected) == 0,
               "speech presence cannot animate rejected background noise")
        expect(VoiceAnimationFilter.visualResponse(for: VoiceAnimationFrame(level: 0, spectrum: [], voiceConfidence: 1)) == 0,
               "a lingering detector confidence cannot animate silent audio")

        var slow = VoiceAnimationEnvelope()
        var fast = VoiceAnimationEnvelope()
        let spoken = VoiceAnimationFrame(level: 0.02, spectrum: quietSpeech, voiceConfidence: 1)
        for _ in 0..<6 {
            slow.accept(spoken)
            slow.advance(elapsed: 1.0 / 30)
        }
        for _ in 0..<24 {
            fast.accept(spoken)
            fast.advance(elapsed: 1.0 / 120)
        }
        expect(abs(slow.level - fast.level) < 0.0001,
               "voice response depends on time, not display or audio callback count")
        var onset = VoiceAnimationEnvelope()
        onset.accept(spoken)
        onset.advance(elapsed: 0.02)
        let target = VoiceAnimationFilter.visualResponse(for: spoken)
        expect(onset.level > target * 0.65 && onset.level < target,
               "a syllable reaches most of its visible energy within 20 ms without snapping")
        expect((onset.spectrum.max() ?? 0) > target * 0.48,
               "speech shape follows promptly instead of trailing behind the loudness")
        let speaking = fast.level
        fast.accept(VoiceAnimationFrame(level: 0, spectrum: quietSpeech, voiceConfidence: 0))
        fast.advance(elapsed: 1.0 / 60)
        expect(fast.level > speaking * 0.86, "one quiet frame does not snap the cloud closed")
        for _ in 0..<4 { fast.advance(elapsed: 1.0 / 60) }
        expect(fast.level < speaking * 0.51 && fast.level > speaking * 0.4,
               "short gaps visibly separate syllables instead of holding a flat voice level")
        for _ in 0..<120 { fast.advance(elapsed: 1.0 / 60) }
        expect(fast.level < 0.001, "a missing or disconnected audio source settles to rest")

        let combined = CombinedVoiceLevels()
        _ = combined.update(source: 0, level: 0.02, spectrum: [1], probability: 0.9, now: 10)
        let overSilence = combined.update(source: 1, level: 0, spectrum: [0], probability: 0.01, now: 10.01)
        expect(overSilence.spectrum == [1], "a silent microphone cannot overwrite active computer speech")
        let overNoise = combined.update(source: 1, level: 0.8, spectrum: [0], probability: 0.1, now: 10.02)
        expect(overNoise.spectrum == [1], "louder background noise cannot win over detected speech")
        let expired = combined.update(source: 1, level: 0, spectrum: [0], probability: 0.01, now: 10.3)
        expect(expired.level == 0, "stopped source levels expire instead of sticking")
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
