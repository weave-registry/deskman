# ADR-2611111000: Hovering over a stacked window gives it the room

**Status:** Accepted
**Date:** 2026-11-11
**Drivers:** The user: "if we have two windows … vertically stacked, when you hover over the window, it expands it at
least three quarters vertically, doesn't hide the window below it or above it, but adds more real estate. And then once
the mouse moves off it, it will snap back."

## Context

- Smart Arrange and the snap zones put up to two windows on top of each other (`ZonePlanner.maxStack`). Each then
  gets half the height, often too little to read.
- Every move Deskman makes is recorded by `IntentLog`: a move by the person pins the window for 30 minutes; a move by
  Deskman marks the window as Deskman's, so learning never takes it for a habit. A hover move is neither: it is
  undone a moment later, and the window's resting place is what counts.

## Decision

1. **`HoverExpand`** (domain) finds the stack around the window under the mouse: visible windows in the same
   column (horizontal overlap at least 80% of the narrower one) that do not overlap it vertically, each within 60 pt
   of the next. It lays the stack out again between the same top and bottom edges, keeping each window's x, width and
   the gaps between them. The hovered window gets at least **three quarters** of the height. The others share the
   rest equally and never drop below **120 pt**. Nothing is hidden and nothing leaves the column.
2. **`HoverService`** (use cases, `HoverPort`) holds the one expansion there is. When the mouse rests on a stacked
   window for a moment, that window expands. Resting on another window of the same stack moves the room to it.
   Leaving the column puts every window back at once. A window that something else moved or resized in the meantime
   is not put back: someone else has it now.
3. Hover moves go through the gateway as the person's (`.person("hovering over a stacked window")`), and through
   `IntentLog` as **transient**: they pin nothing, unpin nothing, and are not Deskman's place. The learner and the
   grid record each hovered window at its resting frame.
4. Never during a meeting, never with the mouse button down (a drag or a resize), never for an app Deskman leaves
   alone, and never with **Expand on Hover** off (in the menu, saved with the preferences, on by default).
5. **`HoverWatch`** (UI adapter): a listen-only mouse event tap for moves, separate from drag-to-snap's.

## Consequences

- A stacked pair reads like an accordion: the window you point at opens, and the other stays visible as a strip.
- An app with a minimum height may take less than three quarters. The frame it actually took is what Deskman
  checks before putting it back.

## Implementation

- Gate: `scripts/gate.sh`, with `HoverExpandTests` (layout) and `HoverServiceTests` (expand, switch, restore,
  hands-off, pins kept, learning sees the resting frame) written before the code.
