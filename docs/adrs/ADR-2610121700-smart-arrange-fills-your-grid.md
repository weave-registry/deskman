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
