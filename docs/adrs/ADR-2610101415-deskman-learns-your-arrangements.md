# ADR-2610101415: Deskman learns your arrangements, suggests them, then automates them

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** The user asked for Deskman to "watch my window activity, learn how I work and organize my windows automatically", and chose: suggest first, then automate; record window titles; track all windows.

## Context

- ADR-2610101046 built Deskman as a hexagon with a language model behind a port. This adds a second way to drive the same window commands: Deskman itself, from what it has seen.
- A wrong automatic move costs more than no move: it scrambles the screen at the moment the person starts work. Trust must be earned per situation, not granted globally.
- Window titles hold private text (mail subjects, document names). The user chose to record them. They stay on this Mac, in a file only the user can read, and the user can erase them.
- macOS shows an app only the windows on the current Space. "All windows" therefore means every window of every app on the current Space, on every display.
- A learned pattern needs no language model. Counting is cheaper, deterministic and testable. The on-device model stays for requests in words.

## Decision

1. **Observe by polling, record settled arrangements.** Every 5 s, read all windows. An arrangement is recorded once, after it stays the same for 30 s. Drags and quick peeks never count.
2. **What a record holds** (`DeskSnapshot`): time, display count, the focused app, and for every window its app, title, display, and placement normalized to that display (0…1, rounded to a 1/60 grid, which holds halves, thirds and quarters exactly).
3. **Context = the set of visible apps + the display count.** Situations are similar when their app sets overlap by Jaccard ≥ 0.6 on the same display count.
4. **Learning is counting** (`Learner`, domain). For each visible window, its usual placement is the most frequent one in similar situations, if seen at least 3 times and in at least 60% of them. Windows of one app are told apart by the title's last segment ("README.md — deskman" → "deskman") when that segment has enough history of its own.
5. **Suggest, then automate** (`TrustLedger`, domain). When a context appears and some window is not in its usual place, Deskman suggests the moves. Three accepts in one context make it automatic there. A dismissal resets the count and snoozes that context for an hour. Undo of an automatic move counts as a dismissal.
6. **Ports.** Driven: `ActivityStore` (records and the ledger), `TimeSource` (named so it does not clash with Swift's `Clock`). Driving: `ActivityPort` (`tick`, `accept`, `dismiss`, `undo`, `pause`, `forget`), implemented by the `ActivityService` use case and driven by a timer in the UI adapter.
7. **Storage:** `~/Library/Application Support/Deskman/`, created with owner-only permissions. The newest 5,000 records, and none older than 90 days.

## Consequences

- Deskman learns nothing in its first hours: three settled sightings per situation is the floor. That is the price of not guessing.
- Polling every 5 s reads every window of every app. Measured cost is small, but it never stops while Deskman runs and learning is on.
- The file holds window titles. "Forget my activity" erases it.

## Implementation

- Gate: `scripts/gate.sh`, with new tests for `Learner`, `TrustLedger` and `ActivityService`, written before the code.
- New targets: `ActivityStoreAdapter` (adapters/secondary). The UI adapter gains the timer and a glass suggestion toast.

## References

- ADR-2610101046 (Deskman's hexagon, ports and gate).

## Amendment 2026-10-10 — see what was learned, arrange on request

- **"What Deskman Learned"** (menu): `Learner.habits` lists one habit per app, its most frequent place and the counts behind it. "Learned" is decided by `usualPlacement`, the function the suggestions use, so the list cannot disagree with what Deskman does. A place within one 1/60 step of a layout takes the layout's name.
- **"Arrange Like Usual"** (menu, ⌘A): `ActivityPort.arrangeNow` applies the learned places at once, in any situation (no similarity gate, because the person asked). It can be undone from the toast, and it earns no trust.
- **Open gap:** the list groups by app only. An app with two windows in two habitual places (two iTerm2 windows: right third, and elsewhere) shows as "still learning", although the suggestions tell the windows apart by title qualifier. The list must group by app and qualifier, as `usualPlacement` does.
