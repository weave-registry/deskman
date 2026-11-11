#!/usr/bin/env bash
# Update Deskman: get the latest code, check it, rebuild the app, and restart the running copy.
#   scripts/update.sh            pull, gate, build, restart
#   scripts/update.sh --no-pull  rebuild and restart what is here (after a local change)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--no-pull" ]; then
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "update: you have uncommitted changes; commit or stash them, or run with --no-pull" >&2
    exit 1
  fi
  git pull --ff-only origin main
fi

# A build that fails its gate is not installed: the running copy keeps going.
scripts/gate.sh 2>&1 | tail -1
scripts/build-app.sh 2>&1 | tail -1

app="$PWD/build/Deskman.app/Contents/MacOS/Deskman"
if pgrep -f "$app" >/dev/null; then
  pkill -f "$app"
  # Wait for it to quit, so its hotkeys and mouse taps are free for the new one.
  for _ in $(seq 1 20); do pgrep -f "$app" >/dev/null || break; sleep 0.25; done
fi
open build/Deskman.app
echo "Deskman updated to $(git log -1 --format='%h %s') and restarted."
