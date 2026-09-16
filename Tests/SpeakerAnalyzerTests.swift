import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@main enum SpeakerAnalyzerTests {
    static func analyze(_ analyzer: SpeakerAnalyzer, _ session: RecordingSession) throws -> [SpeakerTurn] {
        var response: Result<[SpeakerTurn], Error>?
        analyzer.analyze(snapshot: session.snapshot, directory: session.directory) { response = $0 }
        let deadline = Date().addingTimeInterval(60)
        while response == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let response else { fatalError("Speaker analysis timed out") }
        return try response.get()
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("Expected local model and WAV paths") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-speaker-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = URL(fileURLWithPath: args[1])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
        expect(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1, "Fixture must be 16 kHz mono")
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let original = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let samples = original + original + original
        let session = try RecordingSession(root: root, detectSpeakers: true)
        let analyzer = SpeakerAnalyzer(modelURL: model)
        // Analyze a sealed prefix while capture is still running, then continue
        // through forced chunk overlap and finalize both independent sources.
        let prefix = min(samples.count, 26 * 16000)
        try samples.withUnsafeBufferPointer { audio in
            _ = try session.append(source: .computer, samples: audio.baseAddress!, count: prefix, start: 0, speech: true)
        }
        _ = try analyze(analyzer, session)
        try samples.withUnsafeBufferPointer { audio in
            if audio.count > prefix {
                _ = try session.append(source: .computer, samples: audio.baseAddress! + prefix,
                    count: audio.count - prefix, start: Double(prefix) / 16000, speech: true)
            }
            _ = try session.append(source: .microphone, samples: audio.baseAddress!, count: audio.count, start: 0, speech: true)
        }
        try session.finish(duration: Double(samples.count) / 16000)
        let turns = try analyze(analyzer, session)
        expect(!turns.isEmpty && Set(turns.map(\.source)).count == 2, "The real Core ML backend identifies speech in both independent sources")
        expect(turns.allSatisfy { $0.start >= 0 && $0.end <= session.snapshot.duration && $0.end > $0.start },
               "Overlap and final flush cannot stretch the recording timeline")
        let recovered = try RecordingSession(recovering: session.directory)
        let replay = try analyze(SpeakerAnalyzer(modelURL: model), recovered)
        expect(turns == replay, "Restart replay reproduces identities and boundaries from retained source audio")
        let mic = turns.filter { $0.source == .microphone }.map { [$0.start, $0.end, Double($0.speaker)] }
        let computer = turns.filter { $0.source == .computer }.map { [$0.start, $0.end, Double($0.speaker)] }
        expect(mic == computer, "Half-second processing and differing submission boundaries produce the same labels")
        do {
            _ = try analyze(SpeakerAnalyzer(modelURL: nil), recovered)
            fatalError("Missing model unexpectedly succeeded")
        } catch { expect(recovered.snapshot.pending.count == session.snapshot.pending.count, "Speaker failure leaves the transcription queue intact") }
        print("SpeakerAnalyzerTests passed (real model, dual source, chunk overlap, restart replay, missing model)")
    }
}
