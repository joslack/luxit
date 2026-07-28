#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# > 1 )); then
  echo "Usage: $0 [--short|--build|--tag|--display]" >&2
  exit 2
fi
release_version="$(<"$project_dir/VERSION")"
number='(0|[1-9][0-9]*)'

if [[ ! "$release_version" =~ "^${number}\\.${number}\\.${number}\\+[1-9][0-9]*$" ]]; then
  echo "VERSION must use semantic-version+build form, such as 0.11.0+26." >&2
  exit 1
fi
version="${release_version%%+*}"
build="${release_version##*+}"
version_tag="v$version"

case "${1:---display}" in
  --short)
    echo "$version"
    ;;
  --build)
    echo "$build"
    ;;
  --tag)
    echo "$version_tag"
    ;;
  --display)
    echo "$version ($build)"
    ;;
  *)
    echo "Usage: $0 [--short|--build|--tag|--display]" >&2
    exit 2
    ;;
esac
