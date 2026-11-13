#!/bin/bash
# Pulls the latest HomeControl from origin, rebuilds, and relaunches the app.
# Run by the app's "Update" button; safe to run by hand too. Output goes to logs/update.log when run by the app.
{
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BRANCH="${HOMECONTROL_BRANCH:-main}"

echo "[$(date '+%F %T')] updating from $(cat VERSION)"
OLD="$(git rev-parse HEAD)"
git fetch --quiet origin "$BRANCH"
git merge --ff-only "origin/$BRANCH"
echo "now at $(cat VERSION); rebuilding"
# Refresh Python deps only if requirements changed.
if ! git diff --quiet "$OLD" HEAD -- backend/requirements.txt; then ./scripts/setup-backend.sh; fi
./scripts/build-app.sh --open
echo "[$(date '+%F %T')] update complete"
exit 0
}
