import AVFoundation
import Foundation

struct RecordingChunk: Codable, Identifiable, Equatable {
    var id = UUID()
    let source: RecordingAudioSource
    let start: TimeInterval
    var duration: TimeInterval = 0
    var overlap: TimeInterval = 0
    var sealed = false
    var text: String?
    var filename: String { "\(id.uuidString).f32" }
}

struct RecordingSessionSnapshot: Codable {
    let id: UUID
    let createdAt: Date
    var duration: TimeInterval = 0
    var stopped = false
    var chunks: [RecordingChunk] = []
    var pending: [RecordingChunk] {
        chunks.filter { $0.sealed && $0.text == nil }.sorted { $0.start < $1.start }
    }
    var complete: Bool { stopped && pending.isEmpty && chunks.allSatisfy(\.sealed) }

    func entry(state: RecordingTranscriptState) -> TranscriptEntry {
        var previous: [RecordingAudioSource: RecordingChunk] = [:]
        let segments = chunks.sorted { $0.start < $1.start }.compactMap { chunk -> TranscriptSegment? in
            guard let raw = chunk.text, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if chunk.overlap > 0, let prior = previous[chunk.source],
               abs(prior.start + prior.duration - chunk.start - chunk.overlap) < 0.1 {
                text = TranscriptStitcher.removingOverlap(previous: prior.text ?? "", next: text)
            }
            previous[chunk.source] = chunk
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(id: chunk.id, start: chunk.start, source: chunk.source, text: text,
                                     duration: chunk.duration)
        }
        let text = TranscriptSegment.coalescingSources(segments)
            .map { "[\(TranscriptSegment.timestamp($0.start))] \($0.sourceTitle)\n\($0.text)" }.joined(separator: "\n\n")
        return TranscriptEntry(id: id, createdAt: createdAt, duration: duration, source: .recording,
                               text: text, segments: segments, recordingState: state)
    }
}

enum TranscriptStitcher {
    /// Only used for chunks with an actual audio overlap. Require multiple
    /// matching words so a short repeated answer isn't silently removed.
    static func removingOverlap(previous: String, next: String) -> String {
        let a = previous.split(whereSeparator: \.isWhitespace)
        let b = next.split(whereSeparator: \.isWhitespace)
        func key(_ word: Substring) -> String { word.lowercased().filter { $0.isLetter || $0.isNumber } }
        let limit = min(16, min(a.count, b.count))
        guard limit >= 2 else { return next }
        for count in stride(from: limit, through: 2, by: -1) {
            let suffix = a.suffix(count).map(key)
            if suffix.allSatisfy({ !$0.isEmpty }) && suffix == b.prefix(count).map(key) {
                return b.dropFirst(count).joined(separator: " ")
            }
        }
        return next
    }
}

/// Audio is journaled locally before it is offered for transcription. Each
/// source has one bounded open chunk; completed chunks can be retried after a
/// process restart. The lock serializes capture with short metadata operations.
final class RecordingSession {
    static let sampleRate = 16_000
    static let maximumSeconds: Double = 25
    static let silenceSeconds: Double = 0.7
    static let overlapSeconds: Double = 0.8
    let directory: URL
    private let lock = NSRecursiveLock()
    private var value: RecordingSessionSnapshot
    private struct Writer {
        let id: UUID
        let file: FileHandle
        var frames = 0
        var silenceFrames = 0
        var heardSpeech = false
        var tail: [Float] = []
    }
    private var writers: [RecordingAudioSource: Writer] = [:]
    private var manifestURL: URL { directory.appendingPathComponent("session.json") }
    var snapshot: RecordingSessionSnapshot { lock.lock(); defer { lock.unlock() }; return value }

    init(root: URL, id: UUID = UUID(), createdAt: Date = Date()) throws {
        directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        value = RecordingSessionSnapshot(id: id, createdAt: createdAt)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try persist()
    }

    /// Recovery closes the interrupted session, including its last partial
    /// chunk. Raw PCM has no audio-file header that could be left unfinalized.
    init(recovering directory: URL) throws {
        self.directory = directory
        value = try JSONDecoder().decode(RecordingSessionSnapshot.self,
                                         from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        for i in value.chunks.indices where !value.chunks[i].sealed {
            let file = directory.appendingPathComponent(value.chunks[i].filename)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            value.chunks[i].duration = Double(bytes / MemoryLayout<Float>.size) / Double(Self.sampleRate)
            value.chunks[i].sealed = true
            if value.chunks[i].duration <= value.chunks[i].overlap + 0.001 { value.chunks[i].text = "" }
            value.duration = max(value.duration, value.chunks[i].start + value.chunks[i].duration)
        }
        value.stopped = true
        try persist()
    }

    deinit { for writer in writers.values { try? writer.file.close() } }

    @discardableResult
    func append(source: RecordingAudioSource, samples: UnsafePointer<Float>, count: Int,
                start: TimeInterval, speech: Bool) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !value.stopped, count > 0, start.isFinite, start >= 0 else { return false }
        var published = false
        if let writer = writers[source], let chunk = value.chunks.first(where: { $0.id == writer.id }) {
            let expected = chunk.start + Double(writer.frames) / Double(Self.sampleRate)
            let gap = start - expected
            if abs(gap) > 0.08 {
                try seal(source: source, carryOverlap: false)
                published = true
            } else if gap > 0.5 / Double(Self.sampleRate) {
                // Preserve small capture/resampling gaps instead of gradually
                // compressing the source timeline. Large gaps start a new chunk.
                let zeros = [Float](repeating: 0, count: Int((gap * Double(Self.sampleRate)).rounded()))
                published = try zeros.withUnsafeBufferPointer {
                    try append(source: source, samples: $0.baseAddress!, count: $0.count, start: expected, speech: false)
                }
            }
        }
        var consumed = 0
        while consumed < count {
            if writers[source] == nil { try open(source: source, start: start + Double(consumed) / Double(Self.sampleRate)) }
            var writer = writers[source]!
            let amount = min(count - consumed, Int(Self.maximumSeconds * Double(Self.sampleRate)) - writer.frames)
            let data = Data(bytes: samples + consumed, count: amount * MemoryLayout<Float>.size)
            try writer.file.write(contentsOf: data)
            writer.frames += amount
            writer.heardSpeech = writer.heardSpeech || speech
            writer.silenceFrames = speech ? 0 : writer.silenceFrames + amount
            let tailCount = Int(Self.overlapSeconds * Double(Self.sampleRate))
            writer.tail += UnsafeBufferPointer(start: samples + consumed, count: amount)
            if writer.tail.count > tailCount { writer.tail.removeFirst(writer.tail.count - tailCount) }
            writers[source] = writer
            consumed += amount
            let index = value.chunks.firstIndex { $0.id == writer.id }!
            value.chunks[index].duration = Double(writer.frames) / Double(Self.sampleRate)
            value.duration = max(value.duration, value.chunks[index].start + value.chunks[index].duration)
            let atLimit = writer.frames >= Int(Self.maximumSeconds * Double(Self.sampleRate))
            let atPause = writer.heardSpeech && writer.silenceFrames >= Int(Self.silenceSeconds * Double(Self.sampleRate))
            if atLimit || atPause {
                try seal(source: source, carryOverlap: atLimit && !atPause)
                published = true
            }
        }
        return published
    }

    private func open(source: RecordingAudioSource, start: TimeInterval, prefix: [Float] = []) throws {
        var chunk = RecordingChunk(source: source, start: start)
        chunk.overlap = Double(prefix.count) / Double(Self.sampleRate)
        let url = directory.appendingPathComponent(chunk.filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "Luxit.Recording", code: 10, userInfo: [NSLocalizedDescriptionKey: "Could not save recording audio."])
        }
        let file = try FileHandle(forWritingTo: url)
        value.chunks.append(chunk)
        do { try persist() } catch { try? file.close(); throw error }
        var writer = Writer(id: chunk.id, file: file)
        if !prefix.isEmpty {
            try prefix.withUnsafeBytes { try file.write(contentsOf: Data($0)) }
            writer.frames = prefix.count
            writer.tail = prefix
        }
        writers[source] = writer
    }

    private func seal(source: RecordingAudioSource, carryOverlap: Bool) throws {
        guard let writer = writers[source] else { return }
        try writer.file.synchronize()
        try writer.file.close()
        writers.removeValue(forKey: source)
        let index = value.chunks.firstIndex { $0.id == writer.id }!
        value.chunks[index].sealed = true
        value.chunks[index].duration = Double(writer.frames) / Double(Self.sampleRate)
        if value.chunks[index].duration <= value.chunks[index].overlap + 0.001 { value.chunks[index].text = "" }
        try persist()
        if carryOverlap {
            let end = value.chunks[index].start + value.chunks[index].duration
            try open(source: source, start: end - Double(writer.tail.count) / Double(Self.sampleRate), prefix: writer.tail)
        }
    }

    func flush() throws {
        lock.lock(); defer { lock.unlock() }
        for source in RecordingAudioSource.allCases { try seal(source: source, carryOverlap: false) }
    }

    func finish(duration: TimeInterval) throws {
        lock.lock(); defer { lock.unlock() }
        try flush()
        value.stopped = true
        value.duration = max(value.duration, duration)
        try persist()
    }

    func complete(chunkID: UUID, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let i = value.chunks.firstIndex(where: { $0.id == chunkID }) else { return }
        value.chunks[i].text = text
        do { try persist() } catch { value.chunks[i].text = nil; throw error }
    }

    /// Call only after the updated transcript has also been saved to history.
    func removeCompletedAudio(chunk: RecordingChunk) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(chunk.filename))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(chunk.id.uuidString + ".wav"))
    }

    func makeWAV(chunk: RecordingChunk) throws -> URL {
        let input = try FileHandle(forReadingFrom: directory.appendingPathComponent(chunk.filename))
        defer { try? input.close() }
        let output = directory.appendingPathComponent(chunk.id.uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 1)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        while let bytes = try input.read(upToCount: 4096 * MemoryLayout<Float>.size), !bytes.isEmpty {
            let frames = bytes.count / MemoryLayout<Float>.size
            guard frames > 0 else { break }
            buffer.frameLength = AVAudioFrameCount(frames)
            _ = bytes.withUnsafeBytes { raw in
                memcpy(buffer.floatChannelData![0], raw.baseAddress!, frames * MemoryLayout<Float>.size)
            }
            try file.write(from: buffer)
        }
        return output
    }

    private func persist() throws {
        try JSONEncoder().encode(value).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }
}
