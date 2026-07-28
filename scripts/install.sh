#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
installed_app="/Applications/Luxit.app"
legacy_installed_app="/Applications/EdgeWhisper.app"
model_dir="$HOME/Library/Application Support/EdgeWhisper/Models"
parakeet_model_path="$model_dir/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
parakeet_project_model="$project_dir/benchmark/models/ggml/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
parakeet_model_url="https://huggingface.co/ggml-org/parakeet-GGUF/resolve/1a5397ea24a11208f2169d7bd133f4bfe52ae057/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"
parakeet_model_sha256="4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e"
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
if [[ ! -f "$parakeet_model_path" ]]; then
  if [[ -f "$parakeet_project_model" ]] &&
     [[ "$(shasum -a 256 "$parakeet_project_model" | awk '{print $1}')" ==
        "$parakeet_model_sha256" ]]; then
    echo "Installing the local Parakeet Metal Q8 model…"
    cp "$parakeet_project_model" "$parakeet_model_path"
  else
    echo "Downloading the default Parakeet Metal Q8 model (638 MiB)…"
    curl -L --fail --progress-bar \
      "$parakeet_model_url" \
      -o "$parakeet_model_path"
  fi
fi
actual_parakeet_sha256="$(shasum -a 256 "$parakeet_model_path" | awk '{print $1}')"
if [[ "$actual_parakeet_sha256" != "$parakeet_model_sha256" ]]; then
  echo "The Parakeet model failed checksum verification." >&2
  exit 1
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
launch_agent="$launch_agents/com.joslack.luxit.plist"
legacy_launch_agent="$launch_agents/com.edgewhisper.local.plist"
mkdir -p "$launch_agents"
sed "s|__APP_PATH__|$installed_app|g" \
  "$project_dir/Resources/LaunchAgent.plist" > "$launch_agent"

pkill -x Luxit 2>/dev/null || true
pkill -x EdgeWhisper 2>/dev/null || true
launchctl bootout "gui/$UID/com.edgewhisper.local" 2>/dev/null || true
launchctl bootout "gui/$UID/com.joslack.luxit" 2>/dev/null || true
rm -f "$legacy_launch_agent"
launchctl bootstrap "gui/$UID" "$launch_agent"
launchctl kickstart -k "gui/$UID/com.joslack.luxit"

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
