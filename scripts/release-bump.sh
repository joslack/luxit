#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 2
fi
latest_tag="$("$project_dir/scripts/version.sh" --tag)"

if ! git -C "$project_dir" rev-parse -q --verify \
  "refs/tags/$latest_tag^{commit}" >/dev/null; then
  echo "VERSION expects $latest_tag, but that tag does not exist." >&2
  exit 1
fi
if ! git -C "$project_dir" merge-base --is-ancestor \
  "$latest_tag" HEAD; then
  echo "VERSION tag $latest_tag is not an ancestor of HEAD." >&2
  exit 1
fi
if [[ "$(git -C "$project_dir" rev-list --count "$latest_tag..HEAD")" == 0 ]]; then
  echo "No commits exist after $latest_tag." >&2
  exit 1
fi

subjects="$(git -C "$project_dir" log "$latest_tag..HEAD" --format='%s')"
bodies="$(git -C "$project_dir" log "$latest_tag..HEAD" --format='%b')"
if print -r -- "$subjects" |
   grep -Eq '^[a-z]+(\([^)]+\))?!:' ||
   print -r -- "$bodies" |
   grep -Eq '^BREAKING([ -])CHANGE:'; then
  echo major
elif print -r -- "$subjects" |
  grep -Eq '^feat(\([^)]+\))?:'; then
  echo minor
elif print -r -- "$subjects" |
  grep -Eq '^(fix|perf)(\([^)]+\))?:'; then
  echo patch
else
  echo "No release-worthy conventional commit exists after $latest_tag." >&2
  exit 1
fi
