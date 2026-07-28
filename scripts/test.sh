#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/tests"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
module_cache="$build_dir/ModuleCache"
mkdir -p "$build_dir"
mkdir -p "$module_cache"

version="$("$project_dir/scripts/version.sh" --short)"
build_number="$("$project_dir/scripts/version.sh" --build)"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] ||
   [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  echo "Invalid Luxit version metadata." >&2
  exit 1
fi

for script in \
  "$project_dir/scripts/version.sh" \
  "$project_dir/scripts/bump-version.sh" \
  "$project_dir/scripts/release-bump.sh" \
  "$project_dir/scripts/release.sh" \
  "$project_dir/scripts/test-versioning.sh"; do
  zsh -n "$script"
done
"$project_dir/scripts/bump-version.sh" patch --dry-run >/dev/null
"$project_dir/scripts/test-versioning.sh"

if [[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$project_dir/Resources/Info.plist")" != "__LUXIT_VERSION__" ]] ||
   [[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' \
  "$project_dir/Resources/Info.plist")" != "__LUXIT_BUILD__" ]]; then
  echo "Resources/Info.plist must retain version template placeholders." >&2
  exit 1
fi

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  -framework ApplicationServices \
  "$project_dir/Sources/Luxit/CapsLockEventLogic.swift" \
  "$project_dir/Tests/CapsLockEventLogicTests.swift" \
  -o "$build_dir/CapsLockEventLogicTests"

"$build_dir/CapsLockEventLogicTests"

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  -framework Accelerate \
  "$project_dir/Sources/Luxit/LogSpectrumAnalyzer.swift" \
  "$project_dir/Tests/LogSpectrumAnalyzerTests.swift" \
  -o "$build_dir/LogSpectrumAnalyzerTests"

"$build_dir/LogSpectrumAnalyzerTests"

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  "$project_dir/Sources/Luxit/VoiceOrbGeometry.swift" \
  "$project_dir/Tests/VoiceOrbGeometryTests.swift" \
  -o "$build_dir/VoiceOrbGeometryTests"

"$build_dir/VoiceOrbGeometryTests"

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  "$project_dir/Sources/Luxit/VoiceOrbMotion.swift" \
  "$project_dir/Sources/Luxit/VoiceOrbLayout.swift" \
  "$project_dir/Tests/VoiceOrbConfigurationTests.swift" \
  -o "$build_dir/VoiceOrbConfigurationTests"

"$build_dir/VoiceOrbConfigurationTests"

if rg -n \
  'IndicatorStyle|IndicatorColor|IndicatorPlacement|OrbDynamicsPreset|indicator\.(style|color|placement|orbDynamics)' \
  "$project_dir/Sources/Luxit"; then
  echo "Legacy indicator configuration path remains in Sources/Luxit" >&2
  exit 1
fi

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  "$project_dir/Sources/Luxit/ModelCatalog.swift" \
  "$project_dir/Tests/ModelCatalogTests.swift" \
  -o "$build_dir/ModelCatalogTests"

"$build_dir/ModelCatalogTests"

swiftc \
  -swift-version 5 \
  -sdk "$sdk_path" \
  -target arm64-apple-macosx26.0 \
  -module-cache-path "$module_cache" \
  "$project_dir/Sources/Luxit/VoiceAnimationFilter.swift" \
  "$project_dir/Tests/VoiceAnimationFilterTests.swift" \
  -o "$build_dir/VoiceAnimationFilterTests"

"$build_dir/VoiceAnimationFilterTests"
