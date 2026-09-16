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
    var duration: TimeInterval? = nil
    var additionalSource: RecordingAudioSource? = nil
    var sourceTitle: String { additionalSource == nil ? source.title : "Computer + Microphone" }
    static func timestamp(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// Collapse only matching, simultaneous paragraphs from different capture
    /// sources. Original segments stay in history; this is presentation only.
    static func coalescingSources(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: \.isWhitespace)
                .map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        }
        var computers: [[String]: [Int]] = [:]
        for i in segments.indices where segments[i].source == .computer {
            let key = words(segments[i].text)
            if key.count >= 2 { computers[key, default: []].append(i) }
        }
        var paired = Set<Int>()
        var omitted = Set<Int>()
        for i in segments.indices where segments[i].source == .microphone {
            let mic = segments[i]
            let candidates = computers[words(mic.text)] ?? []
            if let match = candidates.first(where: { j in
                guard !paired.contains(j) else { return false }
                let computer = segments[j]
                if let a = mic.duration, let b = computer.duration {
                    let overlap = min(mic.start + a, computer.start + b) - max(mic.start, computer.start)
                    return abs(mic.start - computer.start) <= 1 &&
                        abs(mic.start + a - computer.start - b) <= 1 &&
                        overlap > 0 && overlap >= min(a, b) * 0.8
                }
                // Older histories lack duration: require very close starts.
                return abs(mic.start - computer.start) <= 0.3
            }) {
                paired.insert(match)
                omitted.insert(i)
            }
        }
        return segments.indices.compactMap { i in
            guard !omitted.contains(i) else { return nil }
            var segment = segments[i]
            if paired.contains(i) { segment.additionalSource = .microphone }
            return segment
        }
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
    var displaySegments: [TranscriptSegment]? { segments.map(TranscriptSegment.coalescingSources) }
    var displayText: String {
        guard let segments = displaySegments else { return text }
        return segments.map { "[\(TranscriptSegment.timestamp($0.start))] \($0.sourceTitle)\n\($0.text)" }
            .joined(separator: "\n\n")
    }
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
