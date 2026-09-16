import CoreML
import FluidAudio
import Foundation

/// One stateful CPU pipeline per source. Capture and transcription never wait
/// for it; sealed audio stays in the journal until final analysis is durable.
final class SpeakerAnalyzer {
    static var modelURL: URL? { Bundle.main.url(forResource: "ls_eend_dih3_500ms", withExtension: "mlmodelc") }
    private let queue = DispatchQueue(label: "com.joslack.luxit.speakers", qos: .utility)
    private let url: URL?
    private var model: LSEENDModel?
    private var sessions: [UUID: Session] = [:]
    private final class Track {
        let diarizer: LSEENDDiarizer
        var cursor = 0
        init(model: LSEENDModel) throws {
            diarizer = try LSEENDDiarizer(model: model, timelineConfig: DiarizerTimelineConfig(maxStoredFrames: 1000))
        }
    }
    private final class Session {
        var tracks: [RecordingAudioSource: Track] = [:]
        var consumed = Set<UUID>()
    }

    init(modelURL: URL? = SpeakerAnalyzer.modelURL) { url = modelURL }

    func analyze(snapshot: RecordingSessionSnapshot, directory: URL,
                 completion: @escaping (Result<[SpeakerTurn], Error>) -> Void) {
        queue.async {
            do {
                let turns = try autoreleasepool { try self.process(snapshot: snapshot, directory: directory) }
                DispatchQueue.main.async { completion(.success(turns)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func release(sessionID: UUID) {
        queue.async {
            self.sessions.removeValue(forKey: sessionID)
            if self.sessions.isEmpty { self.model = nil }
        }
    }

    private func process(snapshot: RecordingSessionSnapshot, directory: URL) throws -> [SpeakerTurn] {
        if model == nil {
            guard let url else { throw failure("The local speaker model is unavailable.") }
            let loaded = try LSEENDModel(modelURL: url, computeUnits: .cpuOnly)
            guard loaded.metadata.sampleRate == 8_000, loaded.metadata.maxSpeakers == SpeakerTurn.maximumSpeakers else {
                throw failure("The speaker model is incompatible.")
            }
            model = loaded
        }
        let state = sessions[snapshot.id] ?? Session()
        sessions[snapshot.id] = state
        for chunk in snapshot.chunks.filter(\.sealed).sorted(by: { $0.start < $1.start }) where !state.consumed.contains(chunk.id) {
            guard chunk.start.isFinite, chunk.start >= 0, chunk.duration.isFinite,
                  chunk.duration >= 0, chunk.duration <= RecordingSession.maximumSeconds + 0.1 else {
                throw failure("Invalid speaker-analysis audio interval.")
            }
            let track: Track
            if let existing = state.tracks[chunk.source] { track = existing }
            else {
                track = try Track(model: model!)
                state.tracks[chunk.source] = track
            }
            let begin = Int((chunk.start * 16_000).rounded())
            // Gaps stay gaps; carry-over audio is fed only once. RecordingTimeline
            // already removes paused intervals identically from both sources.
            while track.cursor < begin {
                let count = min(8000, begin - track.cursor)
                try feed([Float](repeating: 0, count: count), to: track)
                track.cursor += count
            }
            let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(chunk.filename))
            defer { try? input.close() }
            let bytes = try input.seekToEnd()
            guard bytes % 4 == 0 else { throw failure("Incomplete speaker-analysis audio.") }
            let frames = Int(bytes / 4)
            let expected = Int((chunk.duration * 16_000).rounded())
            guard abs(frames - expected) <= 1 else { throw failure("Truncated speaker-analysis audio.") }
            let skipped = min(frames, max(0, track.cursor - begin))
            try input.seek(toOffset: UInt64(skipped * 4))
            var remaining = frames - skipped
            while remaining > 0 {
                let count = min(8000, remaining)
                try autoreleasepool {
                    let data = try input.read(upToCount: count * 4) ?? Data()
                    guard data.count == count * 4 else { throw failure("Truncated speaker-analysis audio.") }
                    let samples: [Float] = data.withUnsafeBytes { bytes in
                        stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                    }
                    guard samples.allSatisfy(\.isFinite) else { throw failure("Invalid speaker-analysis samples.") }
                    try feed(samples, to: track)
                }
                track.cursor += count
                remaining -= count
            }
            state.consumed.insert(chunk.id)
        }
        if snapshot.stopped {
            for track in state.tracks.values { try track.diarizer.finalizeSession() }
        }
        return state.tracks.flatMap { source, track in
            track.diarizer.timeline.speakers.values.flatMap { speaker in
                // A person can keep speaking across multiple transcript chunks.
                // Include the model's current turn without finalizing/resetting
                // its session; the next update replaces this tentative interval.
                speaker.finalizedSegments + (snapshot.stopped ? [] : speaker.tentativeSegments)
            }.compactMap { segment -> SpeakerTurn? in
                let begin = max(0, Double(segment.startTime))
                let end = min(Double(track.cursor) / 16_000, Double(segment.endTime))
                guard end > begin else { return nil }
                return SpeakerTurn(source: source, speaker: segment.speakerIndex, start: begin, end: end)
            }
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            return $0.speaker < $1.speaker
        }
    }

    private func feed(_ samples: [Float], to track: Track) throws {
        try track.diarizer.addAudio(samples, sourceSampleRate: 16_000)
        _ = try track.diarizer.process()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Luxit.Speakers", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
