#!/bin/zsh
set -euo pipefail

identity_name="Luxit Local Signing"
legacy_identity_name="EdgeWhisper Local Signing"
login_keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null |
   grep -Fq "\"$identity_name\""; then
  echo "$identity_name already exists."
  exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null |
   grep -Fq "\"$legacy_identity_name\""; then
  echo "$legacy_identity_name already exists and remains valid for Luxit."
  exit 0
fi

staging_dir="$(mktemp -d /private/tmp/edgewhisper-signing.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT

key_path="$staging_dir/signing-key.pem"
cert_path="$staging_dir/signing-certificate.pem"
bundle_path="$staging_dir/signing-identity.p12"
temporary_password="$(openssl rand -hex 24)"

openssl req \
  -x509 \
  -newkey rsa:3072 \
  -keyout "$key_path" \
  -out "$cert_path" \
  -days 3650 \
  -nodes \
  -subj "/CN=$identity_name/O=Luxit Local" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 \
  -export \
  -legacy \
  -out "$bundle_path" \
  -inkey "$key_path" \
  -in "$cert_path" \
  -passout "pass:$temporary_password" \
  -name "$identity_name"

security import "$bundle_path" \
  -k "$login_keychain" \
  -P "$temporary_password" \
  -T /usr/bin/codesign

security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$login_keychain" \
  "$cert_path"

security find-identity -v -p codesigning |
  grep -F "\"$identity_name\""

echo "Created persistent Luxit signing identity in the login keychain."
