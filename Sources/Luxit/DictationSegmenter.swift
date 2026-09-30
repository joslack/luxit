import Foundation

/// One contiguous piece of a dictation, as 16 kHz mono samples.
struct DictationSegment {
    let index: Int
    let start: TimeInterval
    let samples: [Float]
    let voicedSeconds: TimeInterval

    var duration: TimeInterval { Double(samples.count) / Double(DictationSegmenter.sampleRate) }
}

/// Cuts a live dictation into pieces at natural pauses so each piece can be
/// transcribed while the speaker is still talking. Transcription time grows
/// faster than linearly with audio length, so a long dictation transcribed only
/// after the final Caps Lock press kept the speaker waiting for seconds.
///
/// Pieces are never shorter than `minimumSeconds`, which keeps short
/// dictations whole and limits how often the model loses sentence context. A
/// piece that reaches `maximumSeconds` without a pause is cut at its quietest
/// moment. Concatenating every piece reproduces the input exactly.
struct DictationSegmenter {
    static let sampleRate = 16_000
    static let minimumSeconds: TimeInterval = 8
    static let pauseSeconds: TimeInterval = 0.6
    static let maximumSeconds: TimeInterval = 30
    /// A forced cut looks back this far for the quietest frame.
    static let forcedCutSearchSeconds: TimeInterval = 4
    /// Matches the voiced-level threshold used by `DictationAudioMetrics`.
    static let voiceRMS: Float = 0.006

    private static let frameLength = sampleRate / 50
    private static var pauseFrames: Int { Int(pauseSeconds * 50) }
    private static var minimumFrames: Int { Int(minimumSeconds * 50) }
    private static var maximumFrames: Int { Int(maximumSeconds * 50) }

    private var pending: [Float] = []
    private var frameRMS: [Float] = []
    private var silentRun = 0
    private var consumedSamples = 0
    private(set) var sealedCount = 0

    mutating func append(_ samples: [Float]) -> [DictationSegment] {
        pending.append(contentsOf: samples)
        var sealed: [DictationSegment] = []
        while frameRMS.count * Self.frameLength + Self.frameLength <= pending.count {
            let start = frameRMS.count * Self.frameLength
            var energy: Float = 0
            for sample in pending[start..<(start + Self.frameLength)] where sample.isFinite {
                energy += sample * sample
            }
            let rms = (energy / Float(Self.frameLength)).squareRoot()
            frameRMS.append(rms)
            silentRun = rms < Self.voiceRMS ? silentRun + 1 : 0

            if frameRMS.count >= Self.minimumFrames && silentRun >= Self.pauseFrames
                && frameRMS.contains(where: { $0 >= Self.voiceRMS }) {
                // Split the pause so both pieces keep some silence at the cut.
                sealed.append(seal(frames: frameRMS.count - silentRun / 2))
            } else if frameRMS.count >= Self.maximumFrames {
                let searchFrames = Int(Self.forcedCutSearchSeconds * 50)
                let window = (frameRMS.count - searchFrames)..<frameRMS.count
                let quietest = window.min { frameRMS[$0] < frameRMS[$1] } ?? frameRMS.count - 1
                sealed.append(seal(frames: quietest + 1))
            }
        }
        return sealed
    }

    /// Returns everything not yet sealed as the final piece.
    mutating func finish() -> DictationSegment? {
        guard !pending.isEmpty else { return nil }
        let voiced = frameRMS.filter { $0 >= Self.voiceRMS }.count
        let segment = DictationSegment(index: sealedCount, start: seconds(consumedSamples), samples: pending,
                                       voicedSeconds: Double(voiced) / 50)
        sealedCount += 1
        consumedSamples += pending.count
        pending = []
        frameRMS = []
        silentRun = 0
        return segment
    }

    private mutating func seal(frames: Int) -> DictationSegment {
        let sampleCount = frames * Self.frameLength
        let voiced = frameRMS[..<frames].filter { $0 >= Self.voiceRMS }.count
        let segment = DictationSegment(index: sealedCount, start: seconds(consumedSamples),
                                       samples: Array(pending[..<sampleCount]), voicedSeconds: Double(voiced) / 50)
        sealedCount += 1
        consumedSamples += sampleCount
        pending.removeFirst(sampleCount)
        frameRMS.removeFirst(frames)
        silentRun = frameRMS.reversed().prefix { $0 < Self.voiceRMS }.count
        return segment
    }

    private func seconds(_ samples: Int) -> TimeInterval { Double(samples) / Double(Self.sampleRate) }
}

/// Joins the transcripts of consecutive dictation pieces into one dictation.
///
/// The model treats every piece as a new utterance and capitalizes its first
/// word, so a pause mid-sentence produced "their little heads From falling".
/// When the previous piece did not end a sentence, a capitalized common word
/// is lowercased. Other words may be names and are left alone.
enum DictationTranscriptJoiner {
    static func join(_ pieces: [String]) -> String {
        var joined = ""
        for piece in pieces {
            var text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = joined.last, !".?!:\"”)".contains(last) {
                text = lowercasingCommonFirstWord(text)
            }
            joined += joined.isEmpty ? text : " " + text
        }
        return joined
    }

    private static func lowercasingCommonFirstWord(_ text: String) -> String {
        let word = text.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.count > 1, word.first?.isUppercase == true, word.dropFirst().allSatisfy(\.isLowercase),
              continuationWords.contains(word.lowercased()) else { return text }
        return word.lowercased() + text.dropFirst(word.count)
    }

    private static let continuationWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "an", "and", "any", "are", "as", "at", "be", "because",
        "been", "before", "being", "but", "by", "can", "could", "did", "do", "does", "doing", "down", "each",
        "even", "every", "few", "for", "from", "had", "has", "have", "having", "her", "here", "him", "his",
        "how", "if", "in", "into", "is", "it", "it's", "its", "just", "like", "maybe", "me", "more", "most",
        "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our", "out",
        "over", "really", "same", "she", "should", "so", "some", "such", "than", "that", "that's", "the",
        "their", "them", "then", "there", "these", "they", "this", "those", "through", "to", "too", "under",
        "until", "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom",
        "why", "will", "with", "would", "you", "your",
    ]
}

/// Collects the transcripts of one dictation's pieces, which may finish in
/// any order relative to the final Caps Lock press, and reports once when
/// every expected piece is in or any piece has failed. Main queue only.
final class DictationPieces {
    let profile: TranscriptionModelProfile
    /// Known once recording stops.
    var expectedCount: Int?
    var onComplete: ((Result<String, Error>) -> Void)?
    private var texts: [Int: String] = [:]
    private var failure: Error?
    private var completed = false

    init(profile: TranscriptionModelProfile) { self.profile = profile }

    func record(index: Int, result: Result<String, Error>) {
        switch result {
        case .success(let text): texts[index] = text
        case .failure(let error): failure = failure ?? error
        }
        completeIfReady()
    }

    func completeIfReady() {
        guard !completed, let expectedCount, let onComplete else { return }
        if let failure {
            completed = true
            onComplete(.failure(failure))
        } else if (0..<expectedCount).allSatisfy({ texts[$0] != nil }) {
            completed = true
            onComplete(.success(DictationTranscriptJoiner.join((0..<expectedCount).map { texts[$0]! })))
        }
    }
}

/// 16-bit mono PCM WAV, the format the local transcription backends read.
enum DictationWAV {
    static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples.count * 2))
        for sample in samples {
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            append(Int16(clamped * Float(Int16.max)))
        }
        try data.write(to: url, options: .atomic)
    }
}
