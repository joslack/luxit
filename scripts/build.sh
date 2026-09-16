#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/check-whisper-runtime.sh" --check
"$project_dir/scripts/build-speaker-runtime.sh"
speaker_model="$(python3 "$project_dir/scripts/prepare-speaker-model.py")"
speaker_runtime="$project_dir/.build/dependencies/FluidAudio-0.15.7/.build/arm64-apple-macosx/release"

build_dir="$project_dir/.build"
output_app="$project_dir/dist/Luxit.app"
output_archive="$project_dir/dist/Luxit.zip"
staging_root="$(mktemp -d /private/tmp/edgewhisper-build.XXXXXX)"
app_dir="$staging_root/Luxit.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
module_cache="$build_dir/ModuleCache"
version="$("$project_dir/scripts/version.sh" --short)"
build_number="$("$project_dir/scripts/version.sh" --build)"

whisper_prefix="$(brew --prefix whisper-cpp)"
ggml_prefix="$(brew --prefix ggml)"

mkdir -p \
  "$build_dir" \
  "$macos_dir" \
  "$resources_dir" \
  "$module_cache" \
  "$project_dir/dist"

clang \
  -std=c11 \
  -O3 \
  -I"$whisper_prefix/include" \
  -I"$ggml_prefix/include" \
  -c "$project_dir/Sources/Luxit/WhisperBridge.c" \
  -o "$build_dir/WhisperBridge.o"

clang -std=c11 -O3 -I"$whisper_prefix/include" -I"$ggml_prefix/include" \
  -c "$project_dir/Sources/Luxit/VoiceActivityBridge.c" -o "$build_dir/VoiceActivityBridge.o"

swiftc \
  -swift-version 5 \
  -O \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Accelerate \
  -framework AudioToolbox \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreML \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework Metal \
  -framework MetalKit \
  -import-objc-header "$project_dir/Sources/Luxit/WhisperBridge.h" \
  -I"$whisper_prefix/include" \
  -I"$ggml_prefix/include" \
  -L"$whisper_prefix/lib" \
  -L"$ggml_prefix/lib" \
  -Xlinker -rpath -Xlinker "$whisper_prefix/lib" \
  -Xlinker -rpath -Xlinker "$ggml_prefix/lib" \
  -I"$speaker_runtime/Modules" \
  -I"$project_dir/.build/dependencies/FluidAudio-0.15.7/Sources/FastClusterWrapper/include" \
  -I"$project_dir/.build/dependencies/FluidAudio-0.15.7/Sources/MachTaskSelfWrapper/include" \
  -L"$speaker_runtime" -lFluidAudio -lc++ \
  -lwhisper \
  -lparakeet \
  -lggml \
  -lggml-base \
  "$project_dir/Sources/Luxit/CapsLockEventLogic.swift" \
  "$project_dir/Sources/Luxit/AudioInputDevice.swift" \
  "$project_dir/Sources/Luxit/LogSpectrumAnalyzer.swift" \
  "$project_dir/Sources/Luxit/VoiceAnimationFilter.swift" \
  "$project_dir/Sources/Luxit/VoiceAnimationEnvelope.swift" \
  "$project_dir/Sources/Luxit/VoiceActivityAnalyzer.swift" \
  "$project_dir/Sources/Luxit/LatestAudioLevel.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbGeometry.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbLayout.swift" \
  "$project_dir/Sources/Luxit/ModelCatalog.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbMotion.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbDissolution.swift" \
  "$project_dir/Sources/Luxit/MetalOrbRenderer.swift" \
  "$project_dir/Sources/Luxit/SpeakerTranscript.swift" \
  "$project_dir/Sources/Luxit/TranscriptCorrections.swift" \
  "$project_dir/Sources/Luxit/ParakeetWordTiming.swift" \
  "$project_dir/Sources/Luxit/SpeakerAnalyzer.swift" \
  "$project_dir/Sources/Luxit/TranscriptHistory.swift" \
  "$project_dir/Sources/Luxit/TranscriptContent.swift" \
  "$project_dir/Sources/Luxit/RecordingPresence.swift" \
  "$project_dir/Sources/Luxit/TranscriptWindow.swift" \
  "$project_dir/Sources/Luxit/TranscriptPanelLayout.swift" \
  "$project_dir/Sources/Luxit/ComputerAudioRecorder.swift" \
  "$project_dir/Sources/Luxit/RecordingSession.swift" \
  "$project_dir/Sources/Luxit/main.swift" \
  "$build_dir/WhisperBridge.o" \
  "$build_dir/VoiceActivityBridge.o" \
  -o "$macos_dir/Luxit"

cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $version" \
  "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $build_number" \
  "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
cp -R "$speaker_model" "$resources_dir/"
cp "$project_dir/Resources/SpeakerNotices.txt" "$resources_dir/"
cp "$project_dir/Resources/LSEEND-LICENSE.txt" "$resources_dir/"
cp -R "$project_dir/.build/dependencies/FluidAudio-0.15.7/ThirdPartyLicenses" "$resources_dir/"
cp "$project_dir/.build/dependencies/FluidAudio-0.15.7/LICENSE" "$resources_dir/FluidAudio-LICENSE.txt"
xattr -cr "$app_dir"
"$project_dir/scripts/sign-app.sh" "$app_dir"

# Documents may be managed by File Provider, which can attach Finder metadata
# to an unpacked .app seconds after it is created and thereby invalidate the
# signature. Keep the verified build in a ZIP until installation instead.
rm -rf "$output_app"
rm -f "$output_archive"
rm -f "$project_dir/dist/EdgeWhisper.zip"
ditto \
  --norsrc \
  --noextattr \
  --noqtn \
  --noacl \
  -c -k --keepParent \
  "$app_dir" \
  "$output_archive"
rm -rf "$staging_root"

echo "Built Luxit $version ($build_number) at $output_archive"
