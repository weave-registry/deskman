# ADR-2610121130: Keep Arranged — Smart Arrange as a switch

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "smart arrange should be a switch such that it can be watching every time the desktop window changes".

## Context

- Smart Arrange runs on a click or a request. Open a window, close one, restore one, switch desktop, and the layout is stale until the next click.
- The first click arranged by the rules, because the model was asked only after it (fixed in the same change: a click now waits for the model, a few seconds at most, ADR-2610121000).
- A window moved by hand is pinned for 30 minutes (`IntentLog`), and Smart Arrange plans around it. A floating app is never moved (ADR-2610120742).

## Decision

1. **`Preferences.keepArranged`**, off by default, kept across restarts and not erased by "Forget My Activity".
2. **What counts as a change:** the set of visible, movable windows on the desktop on screen. A window opened, closed, minimized or restored, or another desktop, changes it. Moving or resizing a window does not: that is the person's choice, kept by the pin.
3. **When it arranges:** when the set has changed and then stayed the same for 1.5 s, so a burst (an app opening three windows, a desktop switch) causes one arrange. Turning the switch on arranges once at once.
4. **No loop:** after Smart Arrange, the set it left (some windows parked) is the new baseline.
5. It does the same as a click: the model's layout when it has one, the rules otherwise, Undo on the card.
6. **Switches:** "Keep Arranged" in the menu under Smart Arrange, and in the map's Smart Arrange tab. Watching uses the one-second look that bound windows use.

## Consequences

- Windows move without a click. A pin, a floating app, Undo and the switch are the person's controls.
- Learning pauses nothing; what Deskman placed is never learning evidence (`IntentLog`), so it does not learn its own arrangements.

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/KeepArrangedTests.swift` written before the code.

## Amendment 2026-10-12 — the rules follow the model's rules

- Keep Arranged often arranges before the model has answered. The zone rules then put the browser at the side and stacked three terminals.
- Now, while the model has not answered (or its answer was refused), `ModelLayout.house` gives Deskman's own answer through the same `ModelLayout.frames`: browser centered and widest, terminals narrow, two stacked at most, no gap. The zone rules arrange only when no such shape fits the area.
- Test: `withoutTheModelDeskmansOwnAnswerFollowsTheSameRules`, written before the code.

## Amendment 2026-10-12 — Keep Arranged never minimizes for inactivity

- The user: "we seem to have problems with whatsapp and zoom". The trace: "Moved 1 inactive window out of the way: WhatsApp", then the same for Zoom.
- "Inactive" means not in front in the last 30 minutes. A call or a chat is watched, not typed into, so it is rarely in front. Every change Keep Arranged saw minimized them again, whatever the change was.
- Now Keep Arranged (`smartArrange(automatic: true)`) only arranges. Moving inactive windows out of the way is for Smart Arrange the person asks for. Windows with no room at a usable size are still moved out of the way, and the message says so ("No room for …") instead of calling them inactive.
- Test: `keepArrangedNeverMinimizesAWindowForBeingInactive`, written before the code.

## Amendment 2026-10-12 — the active window is never moved

- The user: "if a window is active it should never be modified, otherwise the user can get dizzy ... if there is a better arrangement wait for that window to not be active anymore".
- Waiting for the whole arrangement would wait forever: the next window in front is usually one the plan moves too. So Keep Arranged holds the window in front exactly where it is, as a pinned window, and arranges the others around it. If the best plan would have moved it, Deskman remembers; when another window comes to the front, Keep Arranged runs again and the held window gets its place. The trace: "waiting: the active window keeps its place until you move on".
- A Smart Arrange click still moves every window: the person asked.
- Tests: `keepArrangedNeverMovesTheActiveWindow`, `theBetterArrangementWaitsUntilTheWindowIsNoLongerActive`, `aClickStillMovesTheActiveWindow`, written before the code.
