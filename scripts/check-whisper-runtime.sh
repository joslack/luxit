#!/bin/zsh
set -euo pipefail

minimum_version="1.9.1"
mode="${1:---check}"

if (( $# > 1 )) || [[ "$mode" != "--check" && "$mode" != "--install" ]]; then
  echo "Usage: $0 [--check|--install]" >&2
  exit 2
fi

fail() {
  echo "$1" >&2
  exit 1
}

version_at_least() {
  local actual="$1"
  local minimum="$2"
  local -a actual_parts minimum_parts
  local index left right

  actual_parts=("${(@s:.:)actual}")
  minimum_parts=("${(@s:.:)minimum}")
  (( ${#actual_parts} == 3 && ${#minimum_parts} == 3 )) || return 1

  for index in 1 2 3; do
    left="${actual_parts[index]}"
    right="${minimum_parts[index]}"
    [[ "$left" =~ '^(0|[1-9][0-9]*)$' ]] || return 1
    [[ "$right" =~ '^(0|[1-9][0-9]*)$' ]] || return 1
    (( left > right )) && return 0
    (( left < right )) && return 1
  done
  return 0
}

brew_bin="${LUXIT_BREW_BIN:-$(command -v brew || true)}"
[[ -n "$brew_bin" ]] ||
  fail "Homebrew is required: https://brew.sh"

if ! "$brew_bin" list --versions whisper-cpp >/dev/null 2>&1; then
  if [[ "$mode" == "--install" ]]; then
    echo "Installing whisper-cpp $minimum_version or newer…"
    "$brew_bin" install whisper-cpp
  else
    fail "whisper-cpp $minimum_version or newer is required. Run: brew install whisper-cpp"
  fi
fi

whisper_prefix="$("$brew_bin" --prefix whisper-cpp)"
resolved_prefix="$(cd "$whisper_prefix" 2>/dev/null && pwd -P)" ||
  fail "Homebrew returned an invalid whisper-cpp prefix: $whisper_prefix"
active_version="${resolved_prefix:t}"
active_version="${active_version%%_*}"

if ! version_at_least "$active_version" "$minimum_version"; then
  if [[ "$mode" == "--install" ]]; then
    echo "Upgrading whisper-cpp $active_version to $minimum_version or newer…"
    "$brew_bin" upgrade whisper-cpp
    whisper_prefix="$("$brew_bin" --prefix whisper-cpp)"
    resolved_prefix="$(cd "$whisper_prefix" 2>/dev/null && pwd -P)" ||
      fail "Homebrew returned an invalid whisper-cpp prefix: $whisper_prefix"
    active_version="${resolved_prefix:t}"
    active_version="${active_version%%_*}"
  fi
fi

version_at_least "$active_version" "$minimum_version" ||
  fail "whisper-cpp $active_version is too old; Luxit requires $minimum_version or newer. Run: brew upgrade whisper-cpp"

required_files=(
  "$whisper_prefix/bin/parakeet-cli"
  "$whisper_prefix/bin/whisper-cli"
  "$whisper_prefix/include/parakeet.h"
  "$whisper_prefix/include/whisper.h"
  "$whisper_prefix/lib/libparakeet.dylib"
  "$whisper_prefix/lib/libwhisper.dylib"
)
for required_file in "${required_files[@]}"; do
  [[ -r "$required_file" ]] ||
    fail "whisper-cpp is missing a required runtime artifact: $required_file. Run: brew reinstall whisper-cpp"
done
[[ -x "$whisper_prefix/bin/parakeet-cli" ]] ||
  fail "whisper-cpp parakeet-cli is not executable. Run: brew reinstall whisper-cpp"
