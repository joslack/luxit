import Foundation

enum ModelSelectionError: Error {
    case unsupportedProfile(String)
}

enum WhisperCppTranscriptionStrategy: Int {
    case greedy = 0
}

enum ModelAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum TranscriptionModelProfile: String, CaseIterable {
    case parakeetMetal = "transducer-libparakeet-v3-q8-0-metal"
    case parakeetCPU = "transducer-libparakeet-cli-v3-q8-0"
    case whisperCppGreedy = "whisper-cpp-fast-greedy-v3-turbo-q5_0"

    private static let defaultsKey = "luxit.transcriptionProfile"
    private static let legacyDefaultsKey = "whisper.model"
    private static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeWhisper/Models")
    private static let benchmarkDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/local stt/benchmark/models")
    private static let legacySupportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Luxit/Models")

    static let rankedProfiles: [TranscriptionModelProfile] = [
        .parakeetMetal,
        .parakeetCPU,
        .whisperCppGreedy,
    ]

    var displayName: String {
        switch self {
        case .parakeetMetal:
            "Parakeet (Metal Q8)"
        case .parakeetCPU:
            "Parakeet (CPU Q8)"
        case .whisperCppGreedy:
            "whisper.cpp Greedy"
        }
    }

    var shortName: String {
        switch self {
        case .parakeetMetal:
            "Parakeet Metal"
        case .parakeetCPU:
            "Parakeet CPU"
        case .whisperCppGreedy:
            "whisper.cpp greedy"
        }
    }

    var recommendationLabel: String {
        switch self {
        case .parakeetMetal:
            "Recommended · fastest and most accurate measured option"
        case .parakeetCPU:
            "CPU fallback · same measured accuracy without Metal"
        case .whisperCppGreedy:
            "Whisper fallback · strongest wired Whisper configuration"
        }
    }

    var warmAccuracy: Double {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            0.9391
        case .whisperCppGreedy:
            0.9086
        }
    }

    var warmKeywordRecall: Double {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            0.915
        case .whisperCppGreedy:
            0.852
        }
    }

    var warmLatencyMs: Double {
        switch self {
        case .parakeetMetal:
            93.3
        case .parakeetCPU:
            161.5
        case .whisperCppGreedy:
            1581.1
        }
    }

    var runtimeLifecycle: String {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            "In-app native libparakeet path."
        case .whisperCppGreedy:
            "In-app native whisper.cpp path. Loaded lazily, kept warm, and unloaded after the idle timeout."
        }
    }

    var artifactHints: [String] {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            [
                "Model: ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
                "libparakeet: /opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib",
                "ggml runtime: /opt/homebrew/opt/ggml/lib/libggml.0.dylib",
            ]
        case .whisperCppGreedy:
            [
                "Model: ggml-large-v3-turbo-q5_0.bin",
                "Library: /opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib",
            ]
        }
    }

    var supportsAutomaticDownload: Bool { false }
    var supportsDownload: Bool { false }
    var sourceURL: URL? { nil }
    var supportsLocalSelection: Bool { true }

    var whisperCppStrategy: WhisperCppTranscriptionStrategy? {
        self == .whisperCppGreedy ? .greedy : nil
    }

    var warmHint: String {
        String(
            format: "acc %.3f / kw %.3f / warm %0.0f ms",
            warmAccuracy,
            warmKeywordRecall,
            warmLatencyMs
        )
    }

    var minimumExpectedBytes: Int64 {
        switch self {
        case .whisperCppGreedy:
            540_000_000
        case .parakeetMetal, .parakeetCPU:
            650_000_000
        }
    }

    var modelPathCandidates: [String] {
        switch self {
        case .whisperCppGreedy:
            [
                Self.supportDirectory
                    .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
                    .path,
                Self.legacySupportDirectory
                    .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
                    .path,
                Self.benchmarkDirectory
                    .appendingPathComponent("ggml/ggml-large-v3-turbo-q5_0.bin")
                    .path,
            ]
        case .parakeetMetal, .parakeetCPU:
            [
                Self.supportDirectory
                    .appendingPathComponent("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path,
                Self.legacySupportDirectory
                    .appendingPathComponent("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path,
                Self.benchmarkDirectory
                    .appendingPathComponent("ggml/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path,
            ]
        }
    }

    func modelPathHint(
        fileExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> String? {
        modelPathCandidates.first(where: fileExists)
    }

    func availability(
        fileExists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        },
        commandExists _: (String) -> Bool = { _ in false }
    ) -> ModelAvailability {
        guard modelPathHint(fileExists: fileExists) != nil else {
            return .unavailable(
                "Local model required; Luxit never downloads one when selected."
            )
        }

        let dependencies: [String]
        switch self {
        case .whisperCppGreedy:
            dependencies = [
                "/opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib",
            ]
        case .parakeetMetal, .parakeetCPU:
            dependencies = [
                "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib",
                "/opt/homebrew/opt/ggml/lib/libggml.0.dylib",
            ]
        }
        let missing = dependencies.filter { !fileExists($0) }
        return missing.isEmpty
            ? .available
            : .unavailable(missing.joined(separator: "; "))
    }

    var usesParakeetEngine: Bool {
        self == .parakeetMetal || self == .parakeetCPU
    }

    var parakeetUseGPU: Bool {
        self == .parakeetMetal
    }

    var parakeetLibraryPath: String {
        "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib"
    }

    var parakeetThreads: Int { 4 }

    var downloadSize: String {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            "local model + dylib"
        case .whisperCppGreedy:
            "local whisper.cpp model"
        }
    }

    static var `default`: TranscriptionModelProfile {
        .parakeetMetal
    }

    static var saved: TranscriptionModelProfile {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: defaultsKey) {
            if let profile = TranscriptionModelProfile(rawValue: rawValue) {
                return profile
            }
            switch rawValue {
            case "whisper-cpp-baseline-v3-turbo-q5_0":
                return .whisperCppGreedy
            case "mlx-whisper-turbo-4bit",
                 "whisperkit-large-v3-turbo-coreml",
                 "whisperkit-distil-large-v3":
                return .parakeetMetal
            default:
                break
            }
        }
        if let legacy = defaults.string(forKey: legacyDefaultsKey) {
            switch legacy {
            case "ggml-small-q5_1.bin",
                 "ggml-large-v3-q5_0.bin",
                 "ggml-large-v3-turbo-q5_0.bin":
                return .whisperCppGreedy
            default:
                break
            }
        }
        return `default`
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
