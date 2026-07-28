#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
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

swiftc \
  -swift-version 5 \
  -O \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Accelerate \
  -framework AVFoundation \
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
  -lwhisper \
  -lparakeet \
  -lggml \
  -lggml-base \
  "$project_dir/Sources/Luxit/CapsLockEventLogic.swift" \
  "$project_dir/Sources/Luxit/LogSpectrumAnalyzer.swift" \
  "$project_dir/Sources/Luxit/VoiceAnimationFilter.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbGeometry.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbLayout.swift" \
  "$project_dir/Sources/Luxit/ModelCatalog.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbMotion.swift" \
  "$project_dir/Sources/Luxit/MetalOrbRenderer.swift" \
  "$project_dir/Sources/Luxit/main.swift" \
  "$build_dir/WhisperBridge.o" \
  -o "$macos_dir/Luxit"

cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString $version" \
  "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion $build_number" \
  "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$resources_dir/AppIcon.icns"
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
