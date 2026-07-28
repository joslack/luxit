import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum VoiceOrbGeometryTests {
    static func main() {
        let low = [CGFloat](repeating: 0, count: 23).enumerated().map {
            $0.offset == 3 ? CGFloat(1) : CGFloat(0)
        }
        let high = [CGFloat](repeating: 0, count: 23).enumerated().map {
            $0.offset == 19 ? CGFloat(1) : CGFloat(0)
        }
        let first = VoiceOrbGeometry.points(spectrum: low, level: 0.8)
        let repeated = VoiceOrbGeometry.points(spectrum: low, level: 0.8)
        let changed = VoiceOrbGeometry.points(spectrum: high, level: 0.8)

        expect(first.count == 512, "the default cloud should contain 512 points")
        expect(first == repeated, "the same sound must produce the same cloud")
        expect(first != changed, "different spectra should produce different clouds")
        expect(
            first.allSatisfy {
                $0.x.isFinite &&
                $0.y.isFinite &&
                $0.radius > 0 &&
                (0...1).contains($0.intensity) &&
                $0.velocity > 0 &&
                $0.flowPhase.isFinite &&
                $0.flowPhaseY.isFinite &&
                $0.driftScale > 0
            },
            "all cloud points should be drawable"
        )
        let sortedRadii = first.map(\.radius).sorted()
        let medianRadius = sortedRadii[sortedRadii.count / 2]
        expect(
            sortedRadii.last! > medianRadius * 1.7,
            "the cloud should include a visible long tail of larger grains"
        )
        let jitterA = VoiceOrbGeometry.motionNoise(
            point: 12,
            time: 4.25,
            channel: 0
        )
        let jitterRepeated = VoiceOrbGeometry.motionNoise(
            point: 12,
            time: 4.25,
            channel: 0
        )
        let jitterLater = VoiceOrbGeometry.motionNoise(
            point: 12,
            time: 5.25,
            channel: 0
        )
        expect(jitterA == jitterRepeated, "particle jitter should be repeatable")
        expect(jitterA != jitterLater, "particle jitter should evolve over time")
        expect((-1...1).contains(jitterA), "particle jitter should remain bounded")
        print("VoiceOrbGeometryTests passed")
    }
}
