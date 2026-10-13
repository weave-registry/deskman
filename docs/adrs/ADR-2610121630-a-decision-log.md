# ADR-2610121630: A decision log, in words, for the person

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "i need a log to know why you are making certain decisions".

## Context

- Until now the only record was the system log's keep-arranged trace: an outcome sentence per arrange, read for the user by hand. It did not say why a window was ranked first, why one was kept, which layout path ran, or why a window was pinned.
- Two faults today were found only by reading that trace: false pins, and three windows stacked.

## Decision

1. **`DecisionLog`** port; **`FileDecisionLog`** adapter (in the activity-store adapter, which already keeps Deskman's files) writes `~/Library/Logs/Deskman/decisions.log`, one timestamped line per decision, kept under 5 MB (the older half moves to `decisions.1.log`). Console.app opens it; **Open Decision Log** (⌘L) in the menu.
2. Each arrange writes what started it (the person, or Keep Arranged), the ranking with minutes in front, every window kept in place and why (pinned, being worked in, a meeting app, an app left alone), which layout ran and why (the model and its reason, Deskman's own and why the model's was not used, the zone rules and the area), each move, every app that refused its size, every window put back, and the result.
3. Every pin writes the window, its id, the frames before and after, and where Deskman last put it. Every change of Keep Arranged's state is written once, not every second.
4. A diagnose copy writes nothing: it only looks.

## Consequences

- "Why did it do that" is answered in a file the person can read. Its first minute showed a fault: three windows stacked in a tall strip, where columns became rows (fixed in the same change: a tall area holds two rows at most, `ModelLayout.frames`).
- The log holds window titles. It stays on the Mac, in the user's Library, like the activity store.

## Implementation

- Gate: `scripts/gate.sh`, with `DecisionLogTests` and `NeverThreeStackedInAStripTests` written before the code.
