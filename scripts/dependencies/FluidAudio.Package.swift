// swift-tools-version: 6.0
import PackageDescription

// Luxit uses only diarization. Build upstream source without its CLI, tests,
// or the unrelated downloadable text-normalization binary.
let package = Package(
    name: "FluidAudio",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FluidAudio", type: .static, targets: ["FluidAudio"])],
    targets: [
        .target(name: "FluidAudio", dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
                path: "Sources/FluidAudio", exclude: ["ASR/Parakeet/Unified/benchmark.md"],
                resources: [.process("TTS/LuxTts/G2p/Resources")]),
        .target(name: "FastClusterWrapper", path: "Sources/FastClusterWrapper", publicHeadersPath: "include"),
        .target(name: "MachTaskSelfWrapper", path: "Sources/MachTaskSelfWrapper", publicHeadersPath: "include")
    ], cxxLanguageStandard: .cxx17
)
