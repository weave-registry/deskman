#!/usr/bin/env bash
# Deskman gate (ADR-2610101046). Exits 0 only when every check passes.
# hexa analyze cannot read Swift, so this script is the architecture grade.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "GATE FAIL: $*" >&2; exit 1; }

# 1. Layer purity: each layer may not import the modules listed for it.
forbid() {
  local dir=$1; shift
  for mod in "$@"; do
    if grep -rEn "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+${mod}([[:space:]]|$)" "$dir"; then
      fail "$dir imports $mod"
    fi
  done
}
OUTER="AppKit ApplicationServices FoundationModels SwiftUI Carbon"
ADAPTERS="AccessibilityAdapter FoundationModelsAdapter ActivityStoreAdapter ProcessesAdapter DeskmanUI"
forbid Sources/domain $OUTER DeskmanPorts DeskmanUseCases $ADAPTERS
forbid Sources/ports $OUTER DeskmanUseCases $ADAPTERS
forbid Sources/usecases $OUTER $ADAPTERS
forbid Sources/adapters/primary/ui FoundationModels ApplicationServices DeskmanUseCases $ADAPTERS
forbid Sources/adapters/secondary/accessibility FoundationModels SwiftUI DeskmanUseCases $ADAPTERS
forbid Sources/adapters/secondary/foundation-models AppKit ApplicationServices SwiftUI DeskmanUseCases $ADAPTERS
forbid Sources/adapters/secondary/activity-store $OUTER DeskmanUseCases $ADAPTERS
forbid Sources/adapters/secondary/processes $OUTER DeskmanUseCases $ADAPTERS

# 2. Model independence (hexa G1): only the inference adapter names a model.
if grep -rEn "SystemLanguageModel|LanguageModelSession|import FoundationModels([[:space:]]|$)" Sources \
     | grep -v "^Sources/adapters/secondary/foundation-models/"; then
  fail "a model is named outside the inference adapter"
fi

# 3. The build. An import of an undeclared target is an error, not a warning.
swift build --explicit-target-dependency-import-check error

# 4. The tests. Zero tests is a failed gate, not a pass.
out=$(swift test 2>&1) || { echo "$out"; fail "tests failed"; }
echo "$out" | grep -E "Test run with|passed|failed" | tail -3
n=$(echo "$out" | grep -Eo "Test run with [0-9]+ test" | grep -Eo "[0-9]+" | tail -1 || true)
[ "${n:-0}" -gt 0 ] || fail "vacuous gate: 0 tests ran"

echo "GATE PASS: $n tests, layers clean"
