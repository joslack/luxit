#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /private/tmp/luxit-versioning-tests.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/scripts"
cp \
  "$project_dir/scripts/version.sh" \
  "$project_dir/scripts/bump-version.sh" \
  "$project_dir/scripts/release-bump.sh" \
  "$test_root/scripts/"
print -r -- '1.2.3+7' > "$test_root/VERSION"

git -C "$test_root" init -q -b main
git -C "$test_root" config user.name "Luxit Tests"
git -C "$test_root" config user.email "tests@example.invalid"
git -C "$test_root" add VERSION scripts
git -C "$test_root" commit -q -m 'chore: establish release baseline'
git -C "$test_root" tag -a v1.2.3 -m 'v1.2.3'

print -r -- 'docs' > "$test_root/change"
git -C "$test_root" add change
git -C "$test_root" commit -q -m 'docs: clarify usage'
if "$test_root/scripts/release-bump.sh" >/dev/null 2>&1; then
  echo "Documentation-only history unexpectedly requested a release." >&2
  exit 1
fi

print -r -- 'fix' >> "$test_root/change"
git -C "$test_root" add change
git -C "$test_root" commit -q -m 'fix(audio): preserve quiet speech'
[[ "$("$test_root/scripts/release-bump.sh")" == patch ]]

print -r -- 'feature' >> "$test_root/change"
git -C "$test_root" add change
git -C "$test_root" commit -q -m 'feat(orb): improve contrast'
[[ "$("$test_root/scripts/release-bump.sh")" == minor ]]

print -r -- 'breaking' >> "$test_root/change"
git -C "$test_root" add change
git -C "$test_root" commit -q -m 'feat(api)!: simplify model contract'
[[ "$("$test_root/scripts/release-bump.sh")" == major ]]

expected='1.2.3 (7) -> 2.0.0 (8)'
actual="$("$test_root/scripts/bump-version.sh" major --dry-run)"
[[ "$actual" == "$expected" ]]

print -r -- '01.2.3+8' > "$test_root/VERSION"
if "$test_root/scripts/version.sh" --display >/dev/null 2>&1; then
  echo "VERSION accepted a semantic version with a leading zero." >&2
  exit 1
fi

echo "VersioningTests passed"
