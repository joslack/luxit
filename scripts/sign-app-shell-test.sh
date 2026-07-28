#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp_root="$(mktemp -d /private/tmp/luxit-sign-app-test.XXXXXX)"
app_path="$tmp_root/App.app"
fake_bin="$tmp_root/fake-bin"
security_log="$tmp_root/fake-security.log"
codesign_log="$tmp_root/fake-codesign.log"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$app_path/Contents/MacOS" "$fake_bin"
touch "$security_log" "$codesign_log"

cat > "$fake_bin/security" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$FAKE_SECURITY_LOG"
exit 0
EOF

cat > "$fake_bin/codesign" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$FAKE_CODESIGN_LOG"
exit 0
EOF

chmod +x "$fake_bin/security" "$fake_bin/codesign"

export FAKE_SECURITY_LOG="$security_log"
export FAKE_CODESIGN_LOG="$codesign_log"

run_capture() {
  local label="$1"
  shift
  set +e
  PATH="$fake_bin:$PATH" "$@" > "$tmp_root/$label.out" 2>&1
  local command_status=$?
  set -e
  echo "$command_status"
}

assert_failure() {
  local command_status="$1" file="$2" pattern="$3"
  if [[ "$command_status" -eq 0 ]]; then
    echo "Expected failure but command succeeded" >&2
    echo "Output: $(cat "$file")" >&2
    exit 1
  fi
  if ! rg -qF "$pattern" "$file"; then
    echo "Expected output to include: $pattern" >&2
    echo "Output: $(cat "$file")" >&2
    exit 1
  fi
}

assert_success() {
  local command_status="$1"
  if [[ "$command_status" -ne 0 ]]; then
    echo "Expected success but command failed (status=$command_status)" >&2
    exit 1
  fi
}

assert_contains_log() {
  local file="$1" pattern="$2"
  if ! rg -qF -- "$pattern" "$file"; then
    echo "Expected file $file to include: $pattern" >&2
    echo "Log: $(cat "$file")" >&2
    exit 1
  fi
}

missing_identity_status="$(run_capture missing_identity env -u EDGEWHISPER_CODE_SIGN_IDENTITY -u LUXIT_ALLOW_ADHOC_SIGNING "$project_dir/scripts/sign-app.sh" "$app_path")"
assert_failure "$missing_identity_status" "$tmp_root/missing_identity.out" "No signing identity was found for normal builds."
if [[ -s "$codesign_log" ]]; then
  echo "Expected no codesign invocation when identity is missing and ad-hoc is not allowed." >&2
  echo "Log: $(cat "$codesign_log")" >&2
  exit 1
fi

: > "$codesign_log"
adhoc_status="$(run_capture adhoc_allowed env LUXIT_ALLOW_ADHOC_SIGNING=1 "$project_dir/scripts/sign-app.sh" "$app_path")"
assert_success "$adhoc_status"
assert_contains_log "$codesign_log" "--sign"
assert_contains_log "$codesign_log" "-"
assert_contains_log "$codesign_log" "--verify"
assert_contains_log "$codesign_log" "--deep"
assert_contains_log "$codesign_log" "--strict"
assert_contains_log "$codesign_log" "--verbose=2"

: > "$codesign_log"
developer_status="$(run_capture developer_id env -u LUXIT_ALLOW_ADHOC_SIGNING EDGEWHISPER_CODE_SIGN_IDENTITY='Developer ID Application: Luxit Test' "$project_dir/scripts/sign-app.sh" "$app_path")"
assert_success "$developer_status"
assert_contains_log "$codesign_log" 'Developer ID Application: Luxit Test'
assert_contains_log "$codesign_log" "--options"
assert_contains_log "$codesign_log" "runtime"
assert_contains_log "$codesign_log" "--timestamp"
assert_contains_log "$codesign_log" "--sign"

echo "sign-app shell tests passed"
