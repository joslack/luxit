import Accelerate
import Foundation

/// A small real-time spectrum analyzer adapted from AudioKit's `FFTTap`
/// (MIT License, Copyright (c) 2016 Aurelius Prochazka).
///
/// The analyzer applies a Hann window, performs a real FFT with vDSP, and
/// reduces its power bins into logarithmically spaced bands useful for voice.
final class LogSpectrumAnalyzer {
    static let defaultBandCount = 23

    private let fftSize: Int
    private let binCount: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var transferBuffer: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    init?(fftSize: Int = 1024) {
        guard fftSize > 1, fftSize.nonzeroBitCount == 1 else { return nil }
        self.fftSize = fftSize
        binCount = fftSize / 2
        log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return nil
        }
        fftSetup = setup
        window = Array(repeating: 0, count: fftSize)
        transferBuffer = Array(repeating: 0, count: fftSize)
        real = Array(repeating: 0, count: binCount)
        imaginary = Array(repeating: 0, count: binCount)
        magnitudes = Array(repeating: 0, count: binCount)
        vDSP_hann_window(
            &window,
            vDSP_Length(fftSize),
            Int32(vDSP_HANN_NORM)
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func process(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        bandCount: Int = LogSpectrumAnalyzer.defaultBandCount
    ) -> [Float] {
        guard frameCount > 0, sampleRate > 0, bandCount > 0 else {
            return Array(repeating: 0, count: max(0, bandCount))
        }

        vDSP_vclr(&transferBuffer, 1, vDSP_Length(fftSize))
        let copiedCount = min(frameCount, fftSize)
        vDSP_vmul(
            samples,
            1,
            window,
            1,
            &transferBuffer,
            1,
            vDSP_Length(copiedCount)
        )

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!,
                    imagp: imaginaryPointer.baseAddress!
                )
                transferBuffer.withUnsafeBytes { rawBuffer in
                    rawBuffer.baseAddress!
                        .assumingMemoryBound(to: DSPComplex.self)
                        .withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: binCount
                        ) { complexPointer in
                            vDSP_ctoz(
                                complexPointer,
                                2,
                                &split,
                                1,
                                vDSP_Length(binCount)
                            )
                        }
                }
                vDSP_fft_zrip(
                    fftSetup,
                    &split,
                    1,
                    log2n,
                    FFTDirection(FFT_FORWARD)
                )
                vDSP_zvmags(
                    &split,
                    1,
                    &magnitudes,
                    1,
                    vDSP_Length(binCount)
                )
            }
        }

        return Self.logarithmicBands(
            powerBins: magnitudes,
            fftSize: fftSize,
            sampleRate: sampleRate,
            bandCount: bandCount
        )
    }

    static func logarithmicBands(
        powerBins: [Float],
        fftSize: Int,
        sampleRate: Double,
        bandCount: Int
    ) -> [Float] {
        guard !powerBins.isEmpty,
              fftSize > 0,
              sampleRate > 0,
              bandCount > 0 else {
            return Array(repeating: 0, count: max(0, bandCount))
        }

        let minimumFrequency = 90.0
        let maximumFrequency = min(8_000.0, sampleRate * 0.45)
        guard maximumFrequency > minimumFrequency else {
            return Array(repeating: 0, count: bandCount)
        }
        let ratio = pow(
            maximumFrequency / minimumFrequency,
            1 / Double(bandCount)
        )
        var bands = Array(repeating: Float.zero, count: bandCount)

        for band in 0..<bandCount {
            let lowerFrequency = minimumFrequency * pow(ratio, Double(band))
            let upperFrequency = minimumFrequency * pow(
                ratio,
                Double(band + 1)
            )
            let lowerBin = max(
                1,
                min(
                    powerBins.count - 1,
                    Int(floor(lowerFrequency * Double(fftSize) / sampleRate))
                )
            )
            let upperBin = max(
                lowerBin,
                min(
                    powerBins.count - 1,
                    Int(ceil(upperFrequency * Double(fftSize) / sampleRate))
                )
            )
            var power: Float = 0
            for bin in lowerBin...upperBin {
                power += powerBins[bin]
            }
            bands[band] = sqrt(power / Float(upperBin - lowerBin + 1))
        }
        return bands
    }
}
