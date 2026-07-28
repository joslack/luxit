#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
installed_app="/Applications/Luxit.app"
legacy_installed_app="/Applications/EdgeWhisper.app"
model_dir="$HOME/Library/Application Support/EdgeWhisper/Models"
model_path="$model_dir/ggml-large-v3-turbo-q5_0.bin"
model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
vad_model_path="$model_dir/ggml-silero-v6.2.0.bin"
vad_model_url="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
vad_model_sha256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"
  exit 1
fi

if ! brew list whisper-cpp >/dev/null 2>&1; then
  brew install whisper-cpp
fi

mkdir -p "$model_dir"
if [[ ! -f "$model_path" ]]; then
  echo "Downloading the accuracy-focused q5 large-v3-turbo model (574 MB)…"
  curl -L --fail --progress-bar "$model_url" -o "$model_path"
fi
if [[ ! -f "$vad_model_path" ]]; then
  echo "Downloading the local Silero voice-activity model…"
  curl -L --fail --progress-bar "$vad_model_url" -o "$vad_model_path"
fi
actual_vad_sha256="$(shasum -a 256 "$vad_model_path" | awk '{print $1}')"
if [[ "$actual_vad_sha256" != "$vad_model_sha256" ]]; then
  echo "The downloaded Silero voice-activity model failed checksum verification." >&2
  exit 1
fi

if [[ "${1:-}" != "--use-existing-build" ]]; then
  "$project_dir/scripts/build.sh"
fi
if [[ ! -f "$project_dir/dist/Luxit.zip" ]]; then
  echo "Missing dist/Luxit.zip; run scripts/build.sh first."
  exit 1
fi
install_staging="$(mktemp -d /private/tmp/edgewhisper-install.XXXXXX)"
trap 'rm -rf "$install_staging"' EXIT
ditto -x -k "$project_dir/dist/Luxit.zip" "$install_staging"
ditto "$install_staging/Luxit.app" "$installed_app"
xattr -d com.apple.FinderInfo "$installed_app" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$installed_app" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$installed_app"

launch_agents="$HOME/Library/LaunchAgents"
launch_agent="$launch_agents/com.edgewhisper.local.plist"
mkdir -p "$launch_agents"
sed "s|__APP_PATH__|$installed_app|g" \
  "$project_dir/Resources/LaunchAgent.plist" > "$launch_agent"

pkill -x Luxit 2>/dev/null || true
pkill -x EdgeWhisper 2>/dev/null || true
launchctl bootout "gui/$UID/com.edgewhisper.local" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$launch_agent"
launchctl kickstart -k "gui/$UID/com.edgewhisper.local"

if [[ -d "$legacy_installed_app" ]]; then
  legacy_backup="$HOME/.Trash/EdgeWhisper (pre-Luxit).app"
  if [[ -e "$legacy_backup" ]]; then
    legacy_backup="$HOME/.Trash/EdgeWhisper (pre-Luxit $(date +%s)).app"
  fi
  mv "$legacy_installed_app" "$legacy_backup"
  echo "Moved the superseded EdgeWhisper app to Trash."
fi

echo
echo "Luxit is installed and set to launch when you log in."
echo "Approve Microphone, Accessibility, and Input Monitoring when macOS asks."
