#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: sign-app.sh APP_PATH" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$1"
identity="${EDGEWHISPER_CODE_SIGN_IDENTITY:-}"
allow_adhoc_signing="${LUXIT_ALLOW_ADHOC_SIGNING:-0}"

if [[ -z "$identity" ]]; then
  identity="$(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' |
      head -1
  )"
fi

if [[ -z "$identity" ]] &&
   security find-identity -v -p codesigning 2>/dev/null |
     grep -Fq '"Luxit Local Signing"'; then
  identity="Luxit Local Signing"
fi

if [[ -z "$identity" ]] &&
   security find-identity -v -p codesigning 2>/dev/null |
     grep -Fq '"EdgeWhisper Local Signing"'; then
  identity="EdgeWhisper Local Signing"
fi

if [[ "$identity" == "Luxit Local Signing" ||
      "$identity" == "EdgeWhisper Local Signing" ]]; then
  certificate_file="$(mktemp /private/tmp/edgewhisper-certificate.XXXXXX)"
  requirements_file="$(mktemp /private/tmp/edgewhisper-requirements.XXXXXX)"
  cleanup_signing_files() {
    rm -f "$certificate_file" "$requirements_file"
  }
  trap cleanup_signing_files EXIT

  security find-certificate -c "$identity" -p > "$certificate_file"
  certificate_sha="$(
    openssl x509 -in "$certificate_file" -outform DER |
      shasum -a 1 |
      awk '{print toupper($1)}'
  )"
  if [[ -z "$certificate_sha" ]]; then
    echo "Could not determine the local signing certificate fingerprint." >&2
    exit 1
  fi
  print -r -- \
    "designated => identifier \"com.joslack.luxit\" and certificate leaf = H\"$certificate_sha\"" \
    > "$requirements_file"
  codesign \
    --force \
    --deep \
    --sign "$identity" \
    --requirements "$requirements_file" \
    "$app_path"
  echo "Signed with persistent local identity: $identity"
elif [[ -z "$identity" ]]; then
  if [[ "$allow_adhoc_signing" != "1" ]]; then
    cat >&2 <<'EOF'
No signing identity was found for normal builds.
Create and use a persistent identity, then rebuild:
  scripts/create-local-signing-identity.sh

or set EDGEWHISPER_CODE_SIGN_IDENTITY to a valid persistent Developer ID identity.
To explicitly allow ad-hoc signing (non-persistent) set LUXIT_ALLOW_ADHOC_SIGNING=1.
EOF
    exit 1
  fi

  codesign --force --deep --sign - "$app_path"
  echo "Warning: ad-hoc signing; macOS permissions will reset after updates." >&2
else
  codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
  echo "Signed with Developer ID identity: $identity"
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
