#!/bin/zsh
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
python_bin="$workspace_root/benchmark/.venv/bin/python"
if [[ ! -x "$python_bin" ]]; then
  python_bin="$(command -v python3)"
fi

export PYTHONPATH="$workspace_root/benchmark"
export PATH="$workspace_root/benchmark/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

"$python_bin" -m sttbench.server &
service_pid=$!

cleanup() {
  kill "$service_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$workspace_root/benchmark-ui"
echo "Voiceprint: http://localhost:3000"
npm run dev
