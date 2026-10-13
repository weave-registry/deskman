# ADR-2610131157: Deskman learns your grid from your moves, and makes its zones equal

**Status:** Accepted
**Date:** 2026-10-13
**Amends:** ADR-2610121700 (Smart Arrange fills your grid): the grid is no longer fixed.
**Drivers:** The user: "we need to learn new zone configurations then optimize them for equal distribution". Asked what to learn from: "your moves only". Asked what equal means: "equal-size zones" — keep the shape you use, make the zones equal.

## Context

- The grid is fixed: `ZoneGenerator.snapZones` draws five zones, 25% | 50% | 25%, sides split in halves. The hotkeys, drag-to-snap, Smart Arrange, `zoneLabel`, On Screen and the browser-beside-terminal rule all read it.
- The 206 settled records (2026-10-12 to 13, one 5120 × 1440 display) are mostly that grid: edges at 25% and 75% are 786 of the edges seen. Smart Arrange put most of those windows there. A record says `byDeskman: true` for a window that sits where Deskman put it, and nil otherwise; nil mixes "the person placed it" with "the app opened it there". Learning from all records would learn back Deskman's own grid.
- `IntentLog.pinned()` already knows which windows the person placed in the last 30 minutes: a drag, a resize, a snap key, a drop on a zone. A Deskman move clears it.
- A learned grid can feed itself: learn 25/50/25, make it 33/33/33, and the next moves land on 33% edges while the 25% edges are still in the history. Counting both would invent five columns.

## Decision

1. **Records say who placed a window.** `WindowRecord.byPerson: Bool?` is true when the window is in `IntentLog.pinned()` at the time of the record. Nil in older records, which therefore teach no grid. The write shape and the read shape are the same optional field; an old line decodes.
2. **`GridLearner` (domain) learns a shape, not edges.** A shape is the number of columns, left to right, and how many zones each column stacks: `GridShape(rows: [2, 1, 2])`.
   - Evidence: the visible windows with `byPerson == true` on that display, from records of the last 14 days. One window in one place counts once, however many records repeat it.
   - Columns: the left and right edges of the evidence, other than the display's own edges, grouped when they are within 10% of the width of each other. A group with fewer than 3 placements is noise. Two groups closer than 10% are one edge, and the one used last wins: this is what stops the feedback loop.
   - Rows: for each column, the top and bottom edges of the evidence that lies inside it, grouped the same way, within 10% of the height.
   - Nothing is learned (the standard grid stays) with fewer than 5 placements, or when the shape has one zone.
3. **The zones are equal.** Every column gets the same width; the zones of a column get the same height. They tile the visible frame: no gap, no overlap.
4. **Never too small** (ADR-2610121400). A shape that would make a zone narrower than 700 pt or shorter than 400 pt loses its weakest edges (fewest placements) until it fits.
5. **One grid for everything.** `ZoneGenerator.snapZones(on:shape:)` draws the learned shape, and every reader of the grid passes it: snap keys, drag-to-snap, Smart Arrange, `zoneLabel`, On Screen, the browser beside the terminal. A use case, `LearnedGrid`, holds the shape per display and relearns it on the learning tick; the others read it. Nothing new is stored: the shape is derived from the records, so Forget My Activity forgets it too.
6. **The middle** is the widest column, as before. With equal columns, it is the one at the display's center; with an even count, the left of the two at the center.
7. **Seen, logged, and never a move by itself.** What Deskman Knows says which grid is in use, and from how many of the person's moves, as the first line of Your grid. A change of shape is written to the decision log once. A new shape moves no window: it is used at the next arrange or snap.

## Consequences

- On this display, the person's 25/50/25 becomes three columns of 1,707 pt. Zone 3 is narrower than its 2,560 pt today. That is what "equal" asks for.
- The hotkeys reach zones 1 to 5. A learned shape with more than five zones has zones only Smart Arrange and drag-to-snap reach.
- Until the person has made 5 placements under the new flag, nothing changes: today's records carry no `byPerson`.
- A display that is not the one learned on keeps the standard grid.

## Implementation

- Gate: `scripts/gate.sh`, with `GridLearnerTests` written before the code (shape from evidence, equal tiling as a property over every shape, ignored records, the feedback loop, the minimums, old records decode, the recorder's flag, the middle of an equal grid, the snap keys use the learned zones).
- Live: `scripts/diagnose.sh outline` shows the zones On Screen draws.

## Amendment 2026-10-13 — built

- Built as decided. `GridLearnerTests.swift`: 20 tests, written before the code, failing first (no
  `GridShape`, `GridLearner` or `LearnedGrid`). Each of three rules was broken on purpose and the test
  written for it failed, and only that one: the newer edge winning, `byPerson` as the only evidence,
  the minimum size.
- One change from §7: the grid line is the first line of the Your grid section, not a section of
  its own. A last section sat two screens below the habits in a list with no scroll bar.
- The standard-grid line counts progress: "Standard grid. Yours is learned after 5 of your moves (0 so far)."
- `GridPlanner.label` names a whole column of any height ("zones 1+2+3"); before, only two.
- Not evidence (amendment, 2026-10-13): a window smaller than 90% of the smallest zone (700 × 400 pt),
  and an app Deskman leaves alone. Plaud, a 320 × 196 pt widget, was one of the person's first three
  moves. Tests: `aWindowSmallerThanAZoneTeachesNothing`, `anAppDeskmanLeavesAloneTeachesNothing`.
- Known: `WindowRecord` equality now includes `byPerson`, so a pin that expires after 30 minutes
  starts a new settle and one more record. Harmless; it is the same place.
