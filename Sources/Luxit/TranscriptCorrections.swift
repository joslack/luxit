import Foundation

struct TextCorrection: Codable, Equatable, Identifiable {
    var id = UUID()
    var from: String
    var to: String
    var isPattern = false
    private enum CodingKeys: String, CodingKey { case from, to, isPattern }

    init(id: UUID = UUID(), from: String, to: String, isPattern: Bool = false) {
        self.id = id; self.from = from; self.to = to; self.isPattern = isPattern
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        from = try values.decode(String.self, forKey: .from)
        to = try values.decode(String.self, forKey: .to)
        isPattern = try values.decodeIfPresent(Bool.self, forKey: .isPattern) ?? false
    }
}

/// Local, explicit phrase replacements. No inferred dictionary or model prompt.
/// The app accesses this store on the main thread, at transcription boundaries.
final class TranscriptCorrections {
    private struct Document: Codable { var replacements: [TextCorrection] }
    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String
        let isPattern: Bool
    }
    private struct Stamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
        init(_ attributes: [FileAttributeKey: Any]) {
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
    private struct WordTime {
        let start: TimeInterval
        let end: TimeInterval
    }
    private static let tokens = try! NSRegularExpression(pattern: #"\S+"#)
    private let url: URL
    private var stamp: Stamp?
    private var compiled: [Rule] = []
    private(set) var replacements: [TextCorrection] = []
    private(set) var error: String?

    init(url: URL) { self.url = url }

    var summary: String {
        if error != nil { return "Could not load changes · open to review" }
        return replacements.isEmpty ? "Replace words after transcription" :
            "\(replacements.count) saved \(replacements.count == 1 ? "replacement" : "replacements")"
    }

    func reloadIfNeeded() {
        do {
            let current = Stamp(try FileManager.default.attributesOfItem(atPath: url.path))
            guard current != stamp else { return }
            // Cache failed revisions too: don't repeatedly parse an invalid edit.
            stamp = current
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            let rules = try Self.compile(document.replacements)
            replacements = document.replacements
            compiled = rules
            error = nil
        } catch let failure as NSError where failure.domain == NSCocoaErrorDomain &&
            (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError) {
            stamp = nil
            replacements = []
            compiled = []
            error = nil
        } catch {
            // A malformed edit must not stop dictation or discard the last
            // working rules. Never put file contents or transcripts in logs.
            self.error = "Could not read corrections.json. The last valid replacements remain active."
        }
    }

    func save(_ replacements: [TextCorrection]) throws {
        let clean = replacements.map {
            TextCorrection(id: $0.id, from: $0.from.trimmingCharacters(in: .whitespacesAndNewlines),
                           to: $0.to.trimmingCharacters(in: .whitespacesAndNewlines), isPattern: $0.isPattern)
        }
        let rules = try Self.compile(clean)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Document(replacements: clean)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.replacements = clean
        compiled = rules
        stamp = try? Stamp(FileManager.default.attributesOfItem(atPath: url.path))
        error = nil
    }

    private static func compile(_ replacements: [TextCorrection]) throws -> [Rule] {
        try replacements.enumerated().map { index, replacement in
            let terms = replacement.from.split(whereSeparator: \.isWhitespace)
            guard !terms.isEmpty, !replacement.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "LuxitCorrections", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Fill in both phrases for replacement \(index + 1), or remove it."])
            }
            let phrase = replacement.isPattern ? replacement.from :
                terms.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
            // Include combining marks and digits, so a phrase never replaces
            // part of a larger Unicode word, name, or identifier.
            let pattern = #"(?<![\p{L}\p{M}\p{N}_])(?:"# + phrase + #")(?![\p{L}\p{M}\p{N}_])"#
            let expression: NSRegularExpression
            do { expression = try NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
            catch {
                throw NSError(domain: "LuxitCorrections", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Pattern \(index + 1) is invalid. Check its parentheses and brackets."])
            }
            if replacement.isPattern {
                let template = Array(replacement.to)
                var position = 0
                while position < template.count {
                    if template[position] == "\\" { position += 2; continue }
                    if template[position] == "$" {
                        var end = position + 1
                        while end < template.count, template[end].isASCII, template[end].isNumber { end += 1 }
                        if end > position + 1,
                           (Int(String(template[(position + 1)..<end])) ?? Int.max) > expression.numberOfCaptureGroups {
                            throw NSError(domain: "LuxitCorrections", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "Replacement \(index + 1) refers to a captured group that its pattern does not contain."])
                        }
                        position = end
                    } else { position += 1 }
                }
            }
            return Rule(expression: expression, replacement: replacement.to, isPattern: replacement.isPattern)
        }
    }

    func apply(_ result: TranscriptionResult) -> TranscriptionResult {
        reloadIfNeeded()
        guard !compiled.isEmpty, !result.text.isEmpty else { return result }
        let text = NSMutableString(string: result.text)
        var times = Self.characterTimes(text: result.text, words: result.words)
        var changed = false
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        for rule in compiled {
            let input = text as String
            var matches: [NSTextCheckingResult] = []
            var failed = false
            rule.expression.enumerateMatches(in: input, options: .reportProgress,
                range: NSRange(location: 0, length: text.length)) { match, flags, stop in
                if ProcessInfo.processInfo.systemUptime > deadline || flags.contains(.internalError) {
                    failed = true
                    stop.pointee = true
                } else if let match, match.range.length > 0 { matches.append(match) }
            }
            guard !failed else {
                error = "A correction pattern took too long. This transcript was kept unchanged; simplify the pattern."
                return result
            }
            for match in matches.reversed() {
                let replacement = rule.isPattern
                    ? rule.expression.replacementString(for: match, in: input, offset: 0, template: rule.replacement)
                    : rule.replacement
                guard text.substring(with: match.range) != replacement else { continue }
                changed = true
                if times != nil {
                    let range = match.range.location..<(match.range.location + match.range.length)
                    let interval = Self.covering(times![range])
                    times!.replaceSubrange(range, with: repeatElement(interval, count: replacement.utf16.count))
                }
                // Captures are expanded only in Pattern mode. Plain phrase
                // replacements keep dollar signs and backslashes literally.
                text.replaceCharacters(in: match.range, with: replacement)
            }
        }
        guard changed else { return result }
        let corrected = text as String
        guard let times else { return TranscriptionResult(text: corrected) }
        var words: [TranscriptionWord] = []
        for token in Self.tokens.matches(in: corrected, range: NSRange(location: 0, length: text.length)) {
            let range = token.range.location..<(token.range.location + token.range.length)
            guard let time = Self.covering(times[range]) else { return TranscriptionResult(text: corrected) }
            words.append(TranscriptionWord(text: text.substring(with: token.range), start: time.start, end: time.end))
        }
        return TranscriptionResult(text: corrected, words: words)
    }

    private static func covering(_ values: ArraySlice<WordTime?>) -> WordTime? {
        let known = values.compactMap { $0 }
        guard let first = known.first else { return nil }
        return WordTime(start: known.reduce(first.start) { min($0, $1.start) },
                        end: known.reduce(first.end) { max($0, $1.end) })
    }

    private static func characterTimes(text: String, words: [TranscriptionWord]?) -> [WordTime?]? {
        guard let words, !words.isEmpty else { return nil }
        let source = text as NSString
        let tokens = Self.tokens.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard tokens.count == words.count else { return nil }
        var result = [WordTime?](repeating: nil, count: source.length)
        for (token, word) in zip(tokens, words) {
            guard source.substring(with: token.range) == word.text,
                  word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start else { return nil }
            for index in token.range.location..<(token.range.location + token.range.length) {
                result[index] = WordTime(start: word.start, end: word.end)
            }
        }
        return result
    }
}
