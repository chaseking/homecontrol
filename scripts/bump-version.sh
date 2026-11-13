#!/bin/bash
# Bumps VERSION (release.major.minor). Default is minor: every small change or bug fix.
#   scripts/bump-version.sh [minor|major|release]
set -euo pipefail
F="$(cd "$(dirname "$0")/.." && pwd)/VERSION"
IFS=. read -r rel maj min < <(tr -d '[:space:]' < "$F")
case "${1:-minor}" in
  minor)   min=$((min + 1)) ;;
  major)   maj=$((maj + 1)); min=0 ;;
  release) rel=$((rel + 1)); maj=0; min=0 ;;
  *) echo "usage: $0 [minor|major|release]" >&2; exit 2 ;;
esac
echo "$rel.$maj.$min" | tee "$F"
