#!/usr/bin/env bash
# Run a Deskman diagnose inside the app (ADR-2610121000 amendment). Started from a
# terminal, the binary has the terminal's permissions, and most terminals have no
# Accessibility permission, so it sees no windows. `open` starts it as the app,
# with the app's own permission; the output comes back through a file.
#   scripts/diagnose.sh speed | bindings | names | terminals | arrange | outline | menu
set -euo pipefail
cd "$(dirname "$0")/.."
what=${1:?usage: scripts/diagnose.sh bindings|names|terminals|arrange|outline|menu|speed}
shift
[ -d build/Deskman.app ] || { echo "no build/Deskman.app: run scripts/build-app.sh" >&2; exit 1; }
out=$(mktemp -t deskman-diagnose)
trap 'rm -f "$out"' EXIT
# -n: a second copy beside the running one; -W: wait until it quits.
open -W -n build/Deskman.app --args "--diagnose-$what" "$@" --out "$out"
cat "$out"
# The app's own verdict: a diagnose that could not see windows starts with FAILED.
! grep -q '^FAILED' "$out"
