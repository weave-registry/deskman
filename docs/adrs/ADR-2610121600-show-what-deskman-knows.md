# ADR-2610121600: Show everything Deskman knows, in one place

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "how do i see what AI learned", then "create a plan".

## Context

- The map's Learned tab shows habits only: an app's usual place, green when learned, red while learning.
- Deskman knows more, and none of it is shown:
  - focus per window over the last 30 minutes (one sample every 5 s, ADR-2610121400 amendment), which decides who gets the middle;
  - why Keep Arranged did or did not act (`keepArrangedState`: waiting for the active window, paused for a meeting);
  - which zone of the grid each window holds (ADR-2610121700).
- The model's names, the bound projects and the plan's note are shown, but spread over the Now tab, the menu and a caption.
- People trust automation they can inspect. Today the only way to see why a window moved is the system log.

## Decision

1. The Learned tab becomes **"What Deskman Knows"**: the habit map as today, and under it a short list, in words, fitted to the panel's standard size (540 × 460):
   - **Most used now**: the five windows most in front in the last 30 minutes, by the model's name, with minutes.
   - **Your grid**: each window and its zone ("zone 3", "zones 4+5").
   - **Keep Arranged**: its state in one sentence.
   - **Bound projects**: by name.
2. One value type in the domain, `DesktopMap.Knowledge`, filled by the use cases; the UI only draws it. Nothing new is stored: focus and minimums stay in memory for the session, as today.
3. Nothing here moves a window. A line that cannot be filled says so ("Nothing yet").

## Consequences

- The "why did it do that" question has an answer in the app, not in the system log.
- Focus counts still reset on restart. Keeping them across restarts is a separate decision.

## Implementation

- Workplan: `docs/workplans/wp-show-what-deskman-knows.json`.
- Gate: `scripts/gate.sh`, with `KnowledgeTests` written before the code; live: `--diagnose-map` on the Learned tab.

## Amendment 2026-10-13 — built

- Built as planned, with one change: "Your grid" shows the zone each window is in now (`GridPlanner.zoneLabel`), not where Smart Arrange would put it, so it needs no accessor on `SmartArranger`.
- The first picture of the tab said "off" for a Keep Arranged that was on: the state read "off" until the first look. It now starts as "on: it takes its first look within a second" (`KeepArrangedStateTests`).
- "Under a minute" reads "<1 min": 30 s rounded up to "1 min" before.

## Amendment 2026-10-13 — habits as lines

- The user: "drop the habit strip, keep habits as lines". The strip overlapped its labels where several apps share a place.
- The Learned tab is words only. Habits are the first section, learned first ("✓ Slack: … (40 of 43)"); a habit still learning has a Confirm button, which the strip offered as "I like this". The strip's drawing (`habitBox`) is removed; `habitGroups` stays for On Screen, which outlines the habit places on the real screen.
- Test: `HabitLinesTests`, written before the code.

## Amendment 2026-10-13 — habits by zone

- The user: "describe habits by zone". A habit whose place is one of the grid's zones, within 48 pt per edge (`GridPlanner.zoneLabel`), reads by it: "✓ Firefox: zone 3 (84 of 139)", "Calendar: zones 1+2". A place that is not a zone keeps the old words ("a spot 2% wide, 12% tall"), so nothing is claimed that is not so.
- Test: `HabitZoneTests`, written before the code.
