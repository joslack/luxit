#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /private/tmp/luxit-whisper-runtime-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

fake_brew="$test_root/brew"
fake_opt="$test_root/opt/whisper-cpp"
old_keg="$test_root/Cellar/whisper-cpp/1.8.6"
current_keg="$test_root/Cellar/whisper-cpp/1.9.1"
brew_log="$test_root/brew.log"

mkdir -p "$test_root/opt" "$old_keg" \
  "$current_keg/bin" "$current_keg/include" "$current_keg/lib"
for artifact in \
  "$current_keg/bin/parakeet-cli" \
  "$current_keg/bin/whisper-cli" \
  "$current_keg/include/parakeet.h" \
  "$current_keg/include/whisper.h" \
  "$current_keg/lib/libparakeet.dylib" \
  "$current_keg/lib/libwhisper.dylib"; do
  : > "$artifact"
done
chmod +x "$current_keg/bin/parakeet-cli" "$current_keg/bin/whisper-cli"

cat > "$fake_brew" <<'SCRIPT'
#!/bin/zsh
set -euo pipefail

print -r -- "$1" >> "$FAKE_BREW_LOG"
case "$1" in
  list)
    [[ "$FAKE_INSTALLED" == 1 ]]
    print -r -- 'whisper-cpp fake'
    ;;
  --prefix)
    print -r -- "$FAKE_WHISPER_OPT"
    ;;
  install|upgrade)
    ln -sfn "$FAKE_NEW_PREFIX" "$FAKE_WHISPER_OPT"
    ;;
  *)
    exit 2
    ;;
esac
SCRIPT
chmod +x "$fake_brew"

run_check() {
  FAKE_BREW_LOG="$brew_log" \
  FAKE_INSTALLED="${FAKE_INSTALLED:-1}" \
  FAKE_NEW_PREFIX="$current_keg" \
  FAKE_WHISPER_OPT="$fake_opt" \
  LUXIT_BREW_BIN="$fake_brew" \
    "$project_dir/scripts/check-whisper-runtime.sh" "$@"
}

ln -s "$current_keg" "$fake_opt"
run_check --check

missing_header="$fake_opt/include/parakeet.h"
rm "$current_keg/include/parakeet.h"
if output="$(run_check --check 2>&1)"; then
  echo "Runtime validation accepted a missing Parakeet header." >&2
  exit 1
fi
[[ "$output" == *"$missing_header"* ]]
: > "$missing_header"

ln -sfn "$old_keg" "$fake_opt"
: > "$brew_log"
if output="$(run_check --check 2>&1)"; then
  echo "Runtime validation accepted whisper-cpp 1.8.6." >&2
  exit 1
fi
[[ "$output" == *"1.8.6 is too old"* ]]
! grep -q '^upgrade$' "$brew_log"

run_check --install >/dev/null
[[ "$(cd "$fake_opt" && pwd -P)" == "$current_keg" ]]
grep -q '^upgrade$' "$brew_log"

rm "$fake_opt"
: > "$brew_log"
FAKE_INSTALLED=0 run_check --install >/dev/null
[[ "$(cd "$fake_opt" && pwd -P)" == "$current_keg" ]]
grep -q '^install$' "$brew_log"

echo "WhisperRuntimeTests passed"
