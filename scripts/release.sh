#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--push]" >&2
  exit 2
fi
bump="${1:-}"
push_release=false

if [[ "${2:-}" == "--push" ]]; then
  push_release=true
elif [[ -n "${2:-}" ]]; then
  echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--push]" >&2
  exit 2
fi

if [[ -z "$bump" ]]; then
  echo "Usage: $0 <auto|major|minor|patch|X.Y.Z> [--push]" >&2
  exit 2
fi
if [[ "$(git -C "$project_dir" branch --show-current)" != "main" ]]; then
  echo "Releases must be created from main." >&2
  exit 1
fi
if [[ -n "$(git -C "$project_dir" status --short)" ]]; then
  echo "Commit or stash existing changes before releasing." >&2
  exit 1
fi
if ! git -C "$project_dir" rev-parse --verify \
  refs/remotes/origin/main >/dev/null 2>&1; then
  echo "No origin/main tracking ref exists." >&2
  exit 1
fi
if [[ "$(git -C "$project_dir" rev-parse HEAD)" != \
      "$(git -C "$project_dir" rev-parse refs/remotes/origin/main)" ]]; then
  echo "Local main must exactly match origin/main before releasing." >&2
  echo "Fetch and fast-forward main, then try again." >&2
  exit 1
fi

"$project_dir/scripts/bump-version.sh" "$bump" --dry-run
case "$bump" in
  auto)
    resolved_bump="$("$project_dir/scripts/release-bump.sh")"
    ;;
  *)
    resolved_bump="$bump"
    ;;
esac
current="$("$project_dir/scripts/version.sh" --short)"
IFS=. read -r current_major current_minor current_patch <<< "$current"
case "$resolved_bump" in
  major)
    version="$((current_major + 1)).0.0"
    ;;
  minor)
    version="$current_major.$((current_minor + 1)).0"
    ;;
  patch)
    version="$current_major.$current_minor.$((current_patch + 1))"
    ;;
  *)
    version="$resolved_bump"
    ;;
esac
tag="v$version"
if git -C "$project_dir" rev-parse -q --verify \
  "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

original_version="$(<"$project_dir/VERSION")"
version_was_changed=false
restore_version_on_failure() {
  status=$?
  if (( status != 0 )) && $version_was_changed; then
    git -C "$project_dir" restore --staged VERSION >/dev/null 2>&1 || true
    version_tmp="$(mktemp "$project_dir/.version.XXXXXX")"
    print -r -- "$original_version" > "$version_tmp"
    mv "$version_tmp" "$project_dir/VERSION"
    echo "Restored VERSION after the failed release." >&2
  fi
  exit "$status"
}
trap restore_version_on_failure EXIT

"$project_dir/scripts/bump-version.sh" "$resolved_bump"
version_was_changed=true
"$project_dir/scripts/test.sh"
"$project_dir/scripts/build.sh"
git -C "$project_dir" add VERSION
git -C "$project_dir" commit -m "chore(release): $tag"
version_was_changed=false
git -C "$project_dir" tag -a "$tag" -m "Luxit $tag"
trap - EXIT

echo "Created $tag locally."
if $push_release; then
  git -C "$project_dir" push origin main
  git -C "$project_dir" push origin "$tag"
  echo "Pushed $tag; GitHub will publish the release."
else
  echo "Review it, then run:"
  echo "  git push origin main"
  echo "  git push origin $tag"
fi
