#!/bin/zsh
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dependency_dir="$project_dir/.build/dependencies"
runtime_dir="$dependency_dir/FluidAudio-0.15.7"
archive="$dependency_dir/FluidAudio-0.15.7.tar.gz"
checksum="d409ea04e74f19f7725a17d112bdaf0ae7575fe3c95db7e54932e27f2790d3d6"
mkdir -p "$dependency_dir"
if [[ ! -f "$archive" ]]; then
  echo "Downloading the pinned local speaker runtime…" >&2
  curl --fail --location --retry 3 'https://api.github.com/repos/FluidInference/FluidAudio/tarball/41540ea237350afe5117a082b5c28eda642d0612' -o "$archive.tmp"
  mv "$archive.tmp" "$archive"
fi
if [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$checksum" ]]; then
  echo "Speaker runtime checksum mismatch." >&2
  exit 1
fi
if [[ ! -d "$runtime_dir/Sources" ]]; then
  mkdir -p "$runtime_dir"
  tar -xzf "$archive" --strip-components=1 -C "$runtime_dir"
fi
cp "$project_dir/scripts/dependencies/FluidAudio.Package.swift" "$runtime_dir/Package.swift"
rm -f "$runtime_dir/Package@swift-6.2.swift"
swift build --package-path "$runtime_dir" -c release --disable-sandbox --jobs 4 --product FluidAudio >&2
