import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func withSavedCatalogDefaults(_ body: () -> Void) {
    let defaults = UserDefaults.standard
    let previousProfile = defaults.string(forKey: "luxit.transcriptionProfile")
    let previousLegacy = defaults.string(forKey: "whisper.model")

    body()

    if let previousProfile {
        defaults.set(previousProfile, forKey: "luxit.transcriptionProfile")
    } else {
        defaults.removeObject(forKey: "luxit.transcriptionProfile")
    }

    if let previousLegacy {
        defaults.set(previousLegacy, forKey: "whisper.model")
    } else {
        defaults.removeObject(forKey: "whisper.model")
    }
}

@main
private enum ModelCatalogTests {
    static func main() {
        let ranked = TranscriptionModelProfile.rankedProfiles
        expect(ranked.count == 7, "catalog exposes seven ranked profiles")
        expect(
            Set(ranked.map(\.benchmarkRank)) == Set([1, 2, 3, 4, 5, 6, 7]),
            "benchmark ranks are fully populated 1 through 7"
        )

        let wiredProfiles = Set(
            TranscriptionModelProfile.allCases.filter(\.isImplementedInLuxit)
        )
        expect(
            wiredProfiles == Set([
                .whisperCppGreedy,
                .whisperCppBaseline,
                .parakeetMetal,
                .parakeetCPU
            ]),
            "expected wired profiles include both Parakeet profiles"
        )
        expect(
            TranscriptionModelProfile.parakeetMetal.supportsLocalSelection,
            "parakeet metal profile is selectable"
        )
        expect(
            TranscriptionModelProfile.parakeetCPU.supportsLocalSelection,
            "parakeet cpu profile is selectable"
        )
        expect(
            !TranscriptionModelProfile.whisperKitTurbo.supportsLocalSelection,
            "unsupported catalog entries cannot be selected locally"
        )

        let unavailableGreedy = TranscriptionModelProfile.whisperCppGreedy.availability(
            fileExists: { _ in false },
            commandExists: { _ in false }
        )
        expect(
            {
                if case .unavailable = unavailableGreedy { return true }
                return false
            }(),
            "missing files mark a profile unavailable"
        )

        let unavailableParakeet = TranscriptionModelProfile.parakeetMetal.availability(
            fileExists: { path in
                return !path.hasSuffix("ggml-parakeet-tdt-0.6b-v3-q8_0.bin")
            },
            commandExists: { _ in false }
        )
        expect(
            {
                if case .unavailable(let reason) = unavailableParakeet {
                    return reason.contains("Local model required") || reason.contains("Missing")
                }
                return false
            }(),
            "missing Parakeet model and dependencies marks profile unavailable"
        )

        let availableGreedy = TranscriptionModelProfile.whisperCppGreedy.availability(
            fileExists: { _ in true },
            commandExists: { _ in true }
        )
        expect(availableGreedy == .available, "all dependencies present marks a profile available")

        let greedyCandidates =
            TranscriptionModelProfile.whisperCppGreedy.modelPathCandidates
        expect(
            greedyCandidates[0].hasSuffix(
                "EdgeWhisper/Models/ggml-large-v3-turbo-q5_0.bin"
            ),
            "primary whisper.cpp path matches Luxit's flat installed model directory"
        )
        expect(
            TranscriptionModelProfile.whisperCppGreedy.modelPathHint(
                fileExists: { $0 == greedyCandidates[1] }
            ) == greedyCandidates[1],
            "one present model candidate is sufficient"
        )
        expect(
            TranscriptionModelProfile.whisperCppGreedy.modelPathHint(
                fileExists: { _ in false }
            ) == nil,
            "path hint is nil when no candidate exists"
        )
        expect(
                !TranscriptionModelProfile.allCases.contains {
                $0.supportsAutomaticDownload || $0.supportsDownload
            },
            "catalog selection never enables downloads"
        )

        let availableParakeet = TranscriptionModelProfile.parakeetMetal.availability(
            fileExists: { _ in true },
            commandExists: { _ in true }
        )
        expect(availableParakeet == .available, "parakeet availability succeeds when deps exist")

        withSavedCatalogDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "luxit.transcriptionProfile")
            defaults.set("ggml-large-v3-turbo-q5_0.bin", forKey: "whisper.model")
            expect(
                TranscriptionModelProfile.saved == .whisperCppBaseline,
                "legacy whisper.cpp large profile keys still map to baseline"
            )
        }

        print("ModelCatalogTests passed")
    }
}
