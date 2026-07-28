import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func spectrumPeak(
    analyzer: LogSpectrumAnalyzer,
    frequency: Double,
    sampleRate: Double = 48_000,
    frameCount: Int = 1024
) -> Int {
    let samples = (0..<frameCount).map { index in
        Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }
    return samples.withUnsafeBufferPointer { pointer in
        let spectrum = analyzer.process(
            samples: pointer.baseAddress!,
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        return spectrum.indices.max(by: {
            spectrum[$0] < spectrum[$1]
        }) ?? -1
    }
}

@main
private enum LogSpectrumAnalyzerTests {
    static func main() {
        guard let analyzer = LogSpectrumAnalyzer() else {
            fputs("FAIL: could not create FFT analyzer\n", stderr)
            exit(1)
        }

        let lowPeak = spectrumPeak(analyzer: analyzer, frequency: 180)
        let midPeak = spectrumPeak(analyzer: analyzer, frequency: 1_000)
        let highPeak = spectrumPeak(analyzer: analyzer, frequency: 5_000)
        expect(lowPeak >= 0, "low-frequency tone produced no spectrum")
        expect(lowPeak < midPeak, "180 Hz should appear below 1 kHz")
        expect(midPeak < highPeak, "1 kHz should appear below 5 kHz")

        let silence = Array(repeating: Float.zero, count: 1024)
        let silentSpectrum = silence.withUnsafeBufferPointer { pointer in
            analyzer.process(
                samples: pointer.baseAddress!,
                frameCount: silence.count,
                sampleRate: 48_000
            )
        }
        expect(
            silentSpectrum.allSatisfy { $0 == 0 },
            "silence should produce a flat zero spectrum"
        )
        print("LogSpectrumAnalyzerTests passed")
    }
}
