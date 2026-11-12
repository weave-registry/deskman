# ADR-2611121000: Resting a drag on a taken zone splits it by the window's shape

**Status:** Accepted
**Date:** 2026-11-12
**Drivers:** The user: "If I drag a new window into an existing zone and hover there, I want you to then split the
zone based on the window shape itself."

## Context

- Drag-to-snap (ADR-2610101523 §4) puts the dropped window over the whole zone. A window already in it is covered:
  two windows in one place, one hidden.
- Zones are never too small to work in (ADR-2610121400: 700 × 400 pt) and never more than two high
  (`ZonePlanner.maxStack`).

## Decision

1. **`ZoneSplit`** (domain) cuts a zone in two for a dragged window:
   - **Direction from the window's shape.** For each direction, the dragged window's piece is its own extent along the
     cut (its width for side by side, its height for stacked), clamped so both pieces are at least the minimum. The
     direction whose piece is nearest the window's aspect ratio (on a log scale) wins. A tall window goes side by side;
     a wide one stacks.
   - **Side from the mouse.** The dragged window takes the half of the zone the mouse is in: left or right of the
     zone's center, above or below it.
   - **No split that is too small.** A direction where either piece would fall under 700 × 400 pt is not offered.
     When neither fits, there is no split, and the drop snaps as before.
2. **`SnapService`**: a zone is *taken* when another visible window that Deskman may move sits in it
   (`ZoneReturn.place`, the same 48 pt allowance). When a confirmed drag rests on a taken zone, the split is armed.
   While the mouse stays in that zone, the split follows the mouse's side. Leaving the zone disarms it. Dropping with
   the split armed puts the dragged window in its piece and the window that was there in the other. Both moves are the
   person's (`.person("splitting a zone")`). Option still skips the snap.
3. **`DragSnap`** (UI adapter) says a rest after the mouse has stayed within 4 pt for 0.5 s, and draws the two pieces
   in the overlay: green for the dragged window, outlined for the one that will move.

## Consequences

- One zone can hold two windows without hiding either. Drop without resting and it snaps exactly as before.
- A zone that is already a stacked half usually cannot stack again (its pieces would be under 400 pt). It can still
  split side by side when it is wide enough.

## Implementation

- Gate: `scripts/gate.sh`, with `ZoneSplitTests` (direction, side, size, minimums) and `SplitDragTests` (rest on a
  taken zone splits it, an empty zone does not, leaving disarms, Option skips) written before the code.
