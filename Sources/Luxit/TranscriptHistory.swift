import Foundation

enum TranscriptSource: String, Codable {
    case dictation
    case recording

    var title: String {
        self == .dictation ? "Dictation" : "Computer + microphone"
    }
}

enum RecordingAudioSource: String, Codable, CaseIterable {
    case microphone, computer
    var title: String { self == .microphone ? "Microphone" : "Computer" }
}

enum RecordingTranscriptState: String, Codable {
    case recording, processing, complete, failed
    var inProgress: Bool { self == .recording || self == .processing }
}

struct TranscriptSegment: Codable, Equatable, Identifiable {
    let id: UUID
    let start: TimeInterval
    let source: RecordingAudioSource
    let text: String
    static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct TranscriptEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let createdAt: Date
    let duration: TimeInterval
    let source: TranscriptSource
    let text: String
    var segments: [TranscriptSegment]? = nil
    var recordingState: RecordingTranscriptState? = nil
}

/// Only transcript text and metadata are retained. Audio remains temporary.
final class TranscriptHistory {
    private(set) var entries: [TranscriptEntry] = []
    private let url: URL
    private var loadError: Error?

    init(url: URL) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                entries = try JSONDecoder().decode([TranscriptEntry].self, from: Data(contentsOf: url))
            }
        } catch {
            // Never replace an unreadable history with an empty one.
            loadError = error
        }
    }

    var error: Error? { loadError }

    func append(_ entry: TranscriptEntry) throws {
        try save(([entry] + entries.filter { $0.id != entry.id }).sorted { $0.createdAt > $1.createdAt })
    }

    func delete(id: UUID) throws {
        try save(entries.filter { $0.id != id })
    }

    private func save(_ updated: [TranscriptEntry]) throws {
        if let loadError { throw loadError }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries = updated
    }
}

/// Uses capture timestamps, so delayed callbacks cannot stretch recordings and
/// both audio tracks remove exactly the same paused intervals.
struct RecordingTimeline {
    let startedAt: TimeInterval
    private(set) var pauses: [Range<TimeInterval>] = []
    private(set) var pausedAt: TimeInterval?

    mutating func pause(at time: TimeInterval) {
        guard pausedAt == nil else { return }
        pausedAt = max(startedAt, time)
    }

    mutating func resume(at time: TimeInterval) {
        guard let start = pausedAt else { return }
        pauses.append(start..<max(start, time))
        pausedAt = nil
    }

    func position(at time: TimeInterval) -> TimeInterval? {
        guard time >= startedAt, !(pausedAt.map { time >= $0 } ?? false),
              !pauses.contains(where: { $0.contains(time) }) else { return nil }
        return max(0, time - startedAt - pauses.reduce(0) { total, pause in
            total + max(0, min(time, pause.upperBound) - pause.lowerBound)
        })
    }

    func duration(at time: TimeInterval) -> TimeInterval {
        position(at: pausedAt ?? time) ?? max(0, (pausedAt ?? time) - startedAt -
            pauses.reduce(0) { $0 + $1.countSeconds })
    }
}

private extension Range where Bound == TimeInterval {
    var countSeconds: TimeInterval { upperBound - lowerBound }
}
