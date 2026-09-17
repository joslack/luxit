#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-speaker-runtime.sh"
model="$(python3 "$project_dir/scripts/prepare-speaker-model.py")"
runtime="$project_dir/.build/dependencies/FluidAudio-0.15.7"
build="$runtime/.build/arm64-apple-macosx/release"
tests="$project_dir/.build/tests"
mkdir -p "$tests/ModuleCache"
swiftc -swift-version 5 -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target arm64-apple-macosx26.0 -module-cache-path "$tests/ModuleCache" \
  -framework AVFoundation -framework CoreML -framework Accelerate \
  -I"$build/Modules" -I"$runtime/Sources/FastClusterWrapper/include" -I"$runtime/Sources/MachTaskSelfWrapper/include" \
  -L"$build" -lFluidAudio -lc++ \
  "$project_dir/Sources/Luxit/SpeakerTranscript.swift" \
  "$project_dir/Sources/Luxit/TranscriptHistory.swift" \
  "$project_dir/Sources/Luxit/RecordingSession.swift" \
  "$project_dir/Sources/Luxit/SpeakerAnalyzer.swift" \
  "$project_dir/Tests/SpeakerAnalyzerTests.swift" -o "$tests/SpeakerAnalyzerTests"
"$tests/SpeakerAnalyzerTests" "$model" "$(brew --prefix whisper-cpp)/share/whisper-cpp/jfk.wav"
