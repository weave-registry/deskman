# ADR-2610101523: Deskman draws its own zones and replaces Hammerspoon's window manager

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** The user: "maybe we should not use hammersmith but create window zones ourselves"; asked what happens to Hammerspoon, chose "Deskman replaces it". Then: "i want to see a virtual representation of my desktop in deskman".
**Supersedes:** ADR-2610101501 Decisions 1–2 (zones read from Hammerspoon). Its planner, activity, intent and parking decisions stand.

## Context

- Fixed layouts drawn by hand fit one display and one window count. Smart Arrange already knows the display's size and shape, how many windows are active, and how active each one is.
- The user's Hammerspoon config (`~/.hammerspoon/init.lua`) is a window manager only: zones, drag-to-snap, snap hotkeys (Ctrl+Cmd+1–6, Ctrl+Alt+1/2/3), a layout banner, layouts per Space. Two window managers on the same keys fight.
- The user wants to see the desktop inside Deskman, with learned habits shown (green learned, red still learning; ADR-2610101501 queue item 6).

## Decision

1. **`ZoneGenerator` (domain) draws the zones** for the display and the active windows, in priority order:
   - One window: the full visible frame; on an ultrawide (aspect ≥ 2), a center column half as wide.
   - Two windows: a main column and a side column. The main share is 50–67%, more the more active the main window is.
   - Three or more on an ultrawide: the main window in a center column of 40–60%, sized by its activity share; the rest stacked in a left and a right column.
   - Three or more otherwise: a main column, the rest stacked in one side column.
   - No zone is smaller than 500×400 pt: a column holds at most ⌊height ÷ 400⌋ windows, and windows beyond that are parked.
   - Upright displays get the same zones turned: rows, not columns.
   - Windows the person placed (ADR-2610101501 intents) keep their place: zones are drawn in the widest full-height strip they leave free.
2. **The Hammerspoon adapter and the `init.lua` export are removed.** `ZoneSource` and `ZoneCatalog` go with them.
3. **The desktop map** (UI adapter): a window that draws each display to scale, its windows, and the zones Smart Arrange would use with the app that would get each one. Learned habits are green, still-learning ones red. An Apply button runs Smart Arrange. Data comes through a driving port; the view computes nothing.
4. **Then, in order:** snap hotkeys (Ctrl+Cmd+1–6 to the focused window's zones), drag-to-snap (a mouse event tap; Option bypasses, as in Hammerspoon), click a red habit to confirm it, then retire the Hammerspoon window manager. Retirement disables the config through git, never deletes it.

## Consequences

- One source of zones: Deskman's. Until step 4 retires Hammerspoon, its drag-to-snap snaps to its own zones; such a drag counts as an intent, so Deskman leaves the window there.
- The user's hand-drawn layouts (Default, Coding, Demo) are no longer used. The generator replaces them with zones sized to the moment.

## Implementation

- Gate: `scripts/gate.sh`, with tests in `Tests/DeskmanTests/ZoneGeneratorTests.swift` written before the code.

## Amendment 2026-10-10 — built

- **Zones:** `ZoneGenerator` as in Decision 1; a property test checks 600 random displays and window counts for overlap, bounds and the 500×400 minimum.
- **Desktop map:** Now / Smart Arrange / Learned, live every 2 s, on every desktop, with a picker for windows on other desktops. A click on a red (still learning) habit confirms it; confirmations are kept in the trust ledger in an optional field, so older ledgers still decode.
- **Snap hotkeys:** Control-Command-1…5 to the five snap zones (the zones drawn for five windows, numbered left to right, top to bottom; on an ultrawide the shape of the old Hammerspoon Default), Control-Command-F to fill the screen.
- **Drag-to-snap:** a listen-only mouse event tap. It snaps only when the window under the mouse moved without changing size, so a click (a Firefox tab) or a resize never snaps; Hammerspoon snapped on any title-bar click, which is what moved Firefox on 2026-10-10. Option skips the snap. An overlay shows the zones, the target in green.
- **A snap is the person's choice:** `IntentLog.personPlaced` pins the window and keeps the place as learning evidence, though Deskman made the move.
- **Firefox:** moves failed until `AXEnhancedUserInterface` was switched off for the length of each move (Firefox animates and applies a move late when it is on). Every move is now read back; a window that does not land is named in the outcome.
- **Hammerspoon:** stopped on the user's word. Its config is untouched; the login item is the user's to remove. Decision 4's "retire through git" is not needed while it stays stopped.

## Amendment 2026-10-12 — the map outlines the real screen

- The user: "like hammerspoon window outline we should do the same controlled by desktop map". Hammerspoon's Ctrl+Alt+G drew its zones as rounded outlines on the screen.
- The map has a "Show on Screen" switch. On: one click-through panel per display outlines the tab in view. Now: the snap zones, numbered as the keys count them. Smart Arrange: the planned zones, main one marked ★. Learned: green and red habits. Pointing at a box in the map turns its outline green on the screen.
- `DesktopMap.outlines(_:)` (domain) decides what is drawn, in the map's own order, so a box and its outline share an index. The view paints. Tests: `ScreenOutlineTests.swift`.
- First build drew nothing: an `NSPanel` always has a content view, so "install the drawing if there is none" never ran, and an `NSPanel` hides when its app is not in front. `--diagnose-outline [tab]` now reports each panel, whether it is on screen, whether it holds the drawing, and its labels.
