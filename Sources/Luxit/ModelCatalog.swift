import Foundation

enum ModelSelectionError: Error {
    case unsupportedProfile(String)
}

enum WhisperCppTranscriptionStrategy: Int {
    case greedy = 0
    case baseline = 1
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
    case mlx4Bit = "mlx-whisper-turbo-4bit"
    case whisperCppGreedy = "whisper-cpp-fast-greedy-v3-turbo-q5_0"
    case whisperCppBaseline = "whisper-cpp-baseline-v3-turbo-q5_0"
    case whisperKitTurbo = "whisperkit-large-v3-turbo-coreml"
    case whisperKitDistil = "whisperkit-distil-large-v3"

    private static let defaultsKey = "luxit.transcriptionProfile"
    private static let legacyDefaultsKey = "whisper.model"
    private static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeWhisper/Models")
    private static let benchmarkDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/local stt/benchmark/models")
    private static let legacySupportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Luxit/Models")

    static let rankedByBenchmark: [TranscriptionModelProfile] = {
        allCases.sorted { $0.benchmarkRank < $1.benchmarkRank }
    }()

    var benchmarkRank: Int {
        switch self {
        case .parakeetMetal: return 1
        case .parakeetCPU: return 2
        case .mlx4Bit: return 3
        case .whisperCppGreedy: return 4
        case .whisperCppBaseline: return 5
        case .whisperKitTurbo: return 6
        case .whisperKitDistil: return 7
        }
    }

    var displayName: String {
        switch self {
        case .parakeetMetal:
            "Parakeet (Metal Q8)"
        case .parakeetCPU:
            "Parakeet (CPU Q8)"
        case .mlx4Bit:
            "MLX Whisper 4-bit"
        case .whisperCppGreedy:
            "whisper.cpp Greedy"
        case .whisperCppBaseline:
            "whisper.cpp Baseline"
        case .whisperKitTurbo:
            "WhisperKit Turbo"
        case .whisperKitDistil:
            "WhisperKit Distil"
        }
    }

    var shortName: String {
        switch self {
        case .parakeetMetal:
            "Parakeet Metal"
        case .parakeetCPU:
            "Parakeet CPU"
        case .mlx4Bit:
            "MLX 4-bit"
        case .whisperCppGreedy:
            "whisper.cpp greedy"
        case .whisperCppBaseline:
            "whisper.cpp baseline"
        case .whisperKitTurbo:
            "WhisperKit turbo"
        case .whisperKitDistil:
            "WhisperKit distil"
        }
    }

    var recommendationLabel: String {
        switch self {
        case .parakeetMetal:
            return "Benchmark #1 · best measured warm accuracy"
        case .parakeetCPU:
            return "Benchmark #2 · second-best warm metrics"
        case .mlx4Bit:
            return "Benchmark #3 · low-latency local-first path"
        case .whisperCppGreedy:
            return "Benchmark #4"
        case .whisperCppBaseline:
            return "Benchmark #5 (existing Luxit behavior)"
        case .whisperKitTurbo:
            return "Benchmark #6"
        case .whisperKitDistil:
            return "Benchmark #7"
        }
    }

    var warmAccuracy: Double {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            0.9375758121659761
        case .mlx4Bit:
            0.9159004190254191
        case .whisperCppGreedy:
            0.9085925185925185
        case .whisperCppBaseline:
            0.9054586154586155
        case .whisperKitTurbo:
            0.9047463647463647
        case .whisperKitDistil:
            0.8798417554667555
        }
    }

    var warmKeywordRecall: Double {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            0.9109289617486339
        case .mlx4Bit:
            0.8225
        case .whisperCppGreedy:
            0.8516666666666667
        case .whisperCppBaseline:
            0.8483333333333334
        case .whisperKitTurbo:
            0.8516666666666667
        case .whisperKitDistil:
            0.7775
        }
    }

    var warmLatencyMs: Double {
        switch self {
        case .parakeetMetal:
            93.50763659420439
        case .parakeetCPU:
            162.09009429249056
        case .mlx4Bit:
            674.7728236582285
        case .whisperCppGreedy:
            1581.1082327253341
        case .whisperCppBaseline:
            1637.1734117448796
        case .whisperKitTurbo:
            2047.6006436297514
        case .whisperKitDistil:
            1762.1116360765882
        }
    }

    var runtimeLifecycle: String {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            "In-app native libparakeet path."
        case .mlx4Bit:
            "Persistent MLX worker path in benchmark today; Luxit dispatch not wired yet."
        case .whisperCppGreedy, .whisperCppBaseline:
            "In-app native whisper.cpp path. Loaded lazily on first dictation, kept warm and unloaded under idle timeout."
        case .whisperKitTurbo, .whisperKitDistil:
            "WhisperKit CLI process path in benchmark; Luxit dispatch not wired in this release."
        }
    }

    var artifactHints: [String] {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            [
                "Model: ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
                "libparakeet: /opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib",
                "ggml runtime: /opt/homebrew/opt/ggml/lib/libggml.0.dylib"
            ]
        case .mlx4Bit:
            [
                "Model: model.safetensors under benchmark/models/mlx/whisper-large-v3-turbo-asr-4bit",
                "Runtime: python3 + mlx_audio"
            ]
        case .whisperCppGreedy, .whisperCppBaseline:
            [
                "Model: ggml-large-v3-turbo-q5_0.bin",
                "Library: /opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib"
            ]
        case .whisperKitTurbo:
            [
                "Model: openai_whisper-large-v3-v20240930_turbo_632MB",
                "Runtime: whisperkit-cli"
            ]
        case .whisperKitDistil:
            [
                "Model: distil-whisper_distil-large-v3_594MB",
                "Runtime: whisperkit-cli"
            ]
        }
    }

    var supportsAutomaticDownload: Bool { false }


    var sourceURL: URL? { nil }

    var whisperCppStrategy: WhisperCppTranscriptionStrategy? {
        switch self {
        case .whisperCppGreedy:
            .greedy
        case .whisperCppBaseline:
            .baseline
        case .parakeetMetal, .parakeetCPU, .mlx4Bit, .whisperKitTurbo, .whisperKitDistil:
            nil
        }
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
        case .whisperCppGreedy, .whisperCppBaseline:
            540_000_000
        case .parakeetMetal, .parakeetCPU:
            650_000_000
        case .mlx4Bit, .whisperKitTurbo, .whisperKitDistil:
            0
        }
    }

    var isImplementedInLuxit: Bool {
        switch self {
        case .whisperCppGreedy, .whisperCppBaseline, .parakeetMetal, .parakeetCPU:
            return true
        case .mlx4Bit, .whisperKitTurbo, .whisperKitDistil:
            return false
        }
    }

    var supportsLocalSelection: Bool {
        isImplementedInLuxit
    }

    var modelPathCandidates: [String] {
        switch self {
        case .whisperCppGreedy, .whisperCppBaseline:
            [
                TranscriptionModelProfile.supportDirectory
                    .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
                    .path,
                TranscriptionModelProfile.legacySupportDirectory
                    .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
                    .path,
                TranscriptionModelProfile.benchmarkDirectory
                    .appendingPathComponent("ggml/ggml-large-v3-turbo-q5_0.bin")
                    .path
            ]
        case .parakeetMetal, .parakeetCPU:
            [
                TranscriptionModelProfile.supportDirectory
                    .appendingPathComponent("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path,
                TranscriptionModelProfile.legacySupportDirectory
                    .appendingPathComponent("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path,
                TranscriptionModelProfile.benchmarkDirectory
                    .appendingPathComponent("ggml/ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
                    .path
            ]
        case .mlx4Bit:
            [
                TranscriptionModelProfile.supportDirectory
                    .appendingPathComponent(
                        "mlx/whisper-large-v3-turbo-asr-4bit/model.safetensors"
                    )
                    .path,
                TranscriptionModelProfile.benchmarkDirectory
                    .appendingPathComponent("mlx/whisper-large-v3-turbo-asr-4bit/model.safetensors")
                    .path
            ]
        case .whisperKitTurbo:
            [
                TranscriptionModelProfile.supportDirectory
                    .appendingPathComponent(
                        "whisperkit/openai_whisper-large-v3-v20240930_turbo_632MB"
                    )
                    .path,
                TranscriptionModelProfile.benchmarkDirectory
                    .appendingPathComponent(
                        "whisperkit/openai_whisper-large-v3-v20240930_turbo_632MB"
                    )
                    .path
            ]
        case .whisperKitDistil:
            [
                TranscriptionModelProfile.supportDirectory
                    .appendingPathComponent("whisperkit/distil-whisper_distil-large-v3_594MB")
                    .path,
                TranscriptionModelProfile.benchmarkDirectory
                    .appendingPathComponent("whisperkit/distil-whisper_distil-large-v3_594MB")
                    .path
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

    private func collectMissing(
        fileExists: (String) -> Bool,
        paths: [String]
    ) -> [String] {
        paths.filter { path in !fileExists(path) }
    }

    func availability(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        commandExists: (String) -> Bool = { _ in false }
    ) -> ModelAvailability {
        if !isImplementedInLuxit {
            if self == .mlx4Bit {
                return .unavailable(
                    "Not wired into Luxit yet; the benchmark uses a persistent MLX worker."
                )
            }
            if self == .whisperKitTurbo || self == .whisperKitDistil {
                return .unavailable(
                    "Not wired into Luxit yet; the benchmark uses whisperkit-cli."
                )
            }
            return .unavailable("Not wired into Luxit yet")
        }

        guard modelPathHint(fileExists: fileExists) != nil else {
            return .unavailable(
                "Local model required; Luxit never downloads one when selected."
            )
        }

        var missing: [String] = []
        switch self {
        case .whisperCppGreedy, .whisperCppBaseline:
            missing += collectMissing(
                fileExists: fileExists,
                paths: ["/opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib"]
            )
        case .parakeetMetal, .parakeetCPU:
            missing += collectMissing(
                fileExists: fileExists,
                paths: [
                    "/opt/homebrew/opt/whisper-cpp/lib/libparakeet.dylib",
                    "/opt/homebrew/opt/ggml/lib/libggml.0.dylib",
                ]
            )
        case .mlx4Bit:
            if !commandExists("python3") {
                missing.append("Missing command: python3")
            }
        case .whisperKitTurbo, .whisperKitDistil:
            if !commandExists("whisperkit-cli") {
                missing.append("Missing command: whisperkit-cli")
            }
        }

        if !missing.isEmpty {
            return .unavailable(missing.joined(separator: "; "))
        }
        return .available
    }

    var supportsDownload: Bool {
        false
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

    var parakeetThreads: Int {
        4
    }

    var downloadSize: String {
        switch self {
        case .parakeetMetal, .parakeetCPU:
            "local model + dylib"
        case .mlx4Bit:
            "local MLX snapshot"
        case .whisperCppGreedy, .whisperCppBaseline:
            "local whisper.cpp model"
        case .whisperKitTurbo, .whisperKitDistil:
            "local Core ML artifact"
        }
    }

    static var rankedProfiles: [TranscriptionModelProfile] {
        rankedByBenchmark
    }

    static var `default`: TranscriptionModelProfile {
        .whisperCppBaseline
    }

    static var saved: TranscriptionModelProfile {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: defaultsKey),
           let profile = TranscriptionModelProfile(rawValue: rawValue) {
            return profile
        }
        if let legacy = defaults.string(forKey: legacyDefaultsKey) {
            switch legacy {
            case "ggml-small-q5_1.bin",
                 "ggml-large-v3-q5_0.bin",
                 "ggml-large-v3-turbo-q5_0.bin":
                return .whisperCppBaseline
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
