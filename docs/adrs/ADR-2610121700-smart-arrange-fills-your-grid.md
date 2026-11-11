# ADR-2610121700: Smart Arrange fills your grid, and only your grid

**Status:** Accepted
**Date:** 2026-10-12
**Supersedes:** the layout parts of ADR-2610121000 (the model proposes the layout) and of ADR-2610121400.
**Drivers:** The user: "you keep moving my windows around, we have a layout already of 1 over 2, 3 middle, 4 over 5. These are organized to maximize the content and focus area, we should only auto arrange around these boundaries."

## Context

- Smart Arrange drew its own columns: from the model's answer, from Deskman's own layout, or from `ZoneGenerator` in whatever strip kept windows left. Each path needed the same rules enforced separately (browser in the middle, two per column, 700 pt), and each leaked: three stacked windows, three times.
- The person already has a grid: the snap zones, 1 over 2 on the left, 3 in the middle, 4 over 5 on the right, used by the hotkeys and drag-to-snap.

## Decision

1. **`GridPlanner`** (domain) is the only layout. Every place is a snap zone, or a whole side column (1+2 or 4+5) for a window alone in it.
2. A window already in a zone (within 48 pt) **stays**: it is not moved.
3. Zone 3 goes to the window the person named, else the most used browser, else the most used window. Browsers take a whole column each: never stacked. The rest fill 1, 4, 2, 5 in rank order.
4. Kept windows (pinned, being worked in, meetings) block the zones they cover. Windows beyond the free zones are left where they are, named in the message and the decision log, never minimized.
5. The model no longer proposes layouts. It still names windows and binds projects.

## Consequences

- Boundaries never change. Fewer than five windows can leave a zone empty; more than five leave some where they are.
- The model-layout path (`LayoutAdvice`, `LayoutAdvisor`, `FoundationModelsLayoutAdvisor`, most of `ModelLayout`, `--diagnose-layout`, its eval cases) has no caller from Smart Arrange. It is removed by `wp-remove-model-layouts`.

## Implementation

- Gate: `scripts/gate.sh`, with `GridTests` written before the code. Tests of activity-sized columns and model layouts in Smart Arrange were restated or removed with the behavior.

## Amendment 2026-11-11 — a second grid for six or more windows

- The user, 2026-11-11: "second is divide the center by 2 and have 1 over 2, 3 next to 4 then 5 over 6".
  Asked when: "6+ windows". Five zones left a sixth window where it was.
- Decision:
  1. **The second grid is `GridShape.six`, `[2, 1, 1, 2]`**: four equal columns, the middle half split
     into 3 and 4, the sides 1 over 2 and 5 over 6. On 5,120 pt each column is 1,280 pt.
  2. **`GridPlanner.shape(windows:on:learned:)` chooses.** A learned grid (ADR-2610131157, off by
     default) wins. Else the second grid when the windows sharing the display, meetings and pinned
     ones included, outnumber the first grid's zones and a quarter of a landscape display is at least
     700 pt. Else the first grid. Smart Arrange and Keep Arranged ask it on every arrange, so six
     windows become five and the first grid comes back.
  3. **Zone 4 fills second.** Among side columns as near the middle, a full-height one comes before a
     stacked one: the second window goes beside the first, and a second browser takes zone 4.
  4. **The green button knows both grids.** A window in either grid's zone is home; grown, it goes back
     to the place it came from in its own grid (`GridPlanner.grids`).
- Unchanged: the snap keys, drag-to-snap and On Screen use the first grid; zone labels on the map
  name first-grid zones only, so a window in the second grid's 3 or 4 shows its place in words.
- Gate: `scripts/gate.sh`; `SixZoneGridTests`, `SixZoneArrangeTests`, `GreenButtonSecondGridTests`,
  written first and failing first. The zone-4 order was reverted on purpose and
  `sixWindowsFillSixZonesTheBrowserIn3TheNextIn4` failed, and only it.
