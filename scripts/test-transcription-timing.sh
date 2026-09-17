#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
whisper="$(brew --prefix whisper-cpp)"
ggml="$(brew --prefix ggml)"
build="$project_dir/.build/tests"
model="$HOME/Library/Application Support/EdgeWhisper/Models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
if [[ ! -f "$model" ]]; then
  model="$project_dir/benchmark/models/ggml/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
fi
if [[ ! -f "$model" ]]; then
  echo "The real timing test needs the locally installed Parakeet Q8 model. Run scripts/install.sh to provision it." >&2
  exit 1
fi
clang -std=c11 -O3 -I"$whisper/include" -I"$ggml/include" -c "$project_dir/Sources/Luxit/WhisperBridge.c" -o "$build/WhisperBridge.o"
swiftc -swift-version 5 -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
 -target arm64-apple-macosx26.0 -module-cache-path "$build/ModuleCache" \
 -framework IOKit -import-objc-header "$project_dir/Sources/Luxit/WhisperBridge.h" \
 -I"$whisper/include" -I"$ggml/include" -L"$whisper/lib" -L"$ggml/lib" \
 -lwhisper -lparakeet -lggml -lggml-base \
 -Xlinker -rpath -Xlinker "$whisper/lib" -Xlinker -rpath -Xlinker "$ggml/lib" \
 "$project_dir/Sources/Luxit/SpeakerTranscript.swift" \
 "$project_dir/Sources/Luxit/TranscriptHistory.swift" \
 "$project_dir/Sources/Luxit/ParakeetWordTiming.swift" \
 "$project_dir/Tests/ParakeetWordTimingTests.swift" \
 "$build/WhisperBridge.o" "$build/VoiceActivityBridge.o" -o "$build/ParakeetWordTimingTests"
"$build/ParakeetWordTimingTests" "$model" "$whisper/lib/libparakeet.dylib" "$whisper/share/whisper-cpp/jfk.wav"
