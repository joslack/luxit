#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--dry-run]" >&2
  exit 2
fi
requested="${1:-}"
dry_run=false

if [[ "${2:-}" == "--dry-run" ]]; then
  dry_run=true
elif [[ -n "${2:-}" ]]; then
  echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--dry-run]" >&2
  exit 2
fi

current="$("$project_dir/scripts/version.sh" --short)"
current_build="$("$project_dir/scripts/version.sh" --build)"
IFS=. read -r major minor patch <<< "$current"

if [[ "$requested" == "auto" ]]; then
  requested="$("$project_dir/scripts/release-bump.sh")"
fi

case "$requested" in
  major)
    next="$((major + 1)).0.0"
    ;;
  minor)
    next="$major.$((minor + 1)).0"
    ;;
  patch)
    next="$major.$minor.$((patch + 1))"
    ;;
  [0-9]*.[0-9]*.[0-9]*)
    number='(0|[1-9][0-9]*)'
    if [[ ! "$requested" =~ "^${number}\\.${number}\\.${number}$" ]]; then
      echo "Explicit versions must use X.Y.Z semantic versioning." >&2
      exit 2
    fi
    next="$requested"
    ;;
  *)
    echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--dry-run]" >&2
    exit 2
    ;;
esac

IFS=. read -r next_major next_minor next_patch <<< "$next"
if (( next_major < major ||
      (next_major == major && next_minor < minor) ||
      (next_major == major && next_minor == minor &&
       next_patch <= patch) )); then
  echo "Version $next must be greater than $current." >&2
  exit 1
fi

next_build=$((current_build + 1))
echo "$current ($current_build) -> $next ($next_build)"
if $dry_run; then
  exit 0
fi

version_tmp="$(mktemp "$project_dir/.version.XXXXXX")"
trap 'rm -f "$version_tmp"' EXIT
echo "$next+$next_build" > "$version_tmp"
mv "$version_tmp" "$project_dir/VERSION"
trap - EXIT
