# ADR-2610101501: Smart Arrange fills the user's Hammerspoon zones

**Status:** Superseded by ADR-2610101523 (Deskman draws its own zones), 2026-10-10
**Date:** 2026-10-10
**Drivers:** The user: "i want ai to help me arrange the windows in the most efficient use", and "window tiles we can work with hammerspoon".

## Context

- The user runs Hammerspoon with a zone manager (`~/.hammerspoon/init.lua`) for a 5120×1440 display: three layouts (Default, 5 zones; Coding, 3 columns; Demo, 4 zones), drag-to-snap, and a layout per Space. The user edits these zones often (uncommitted changes on 2026-10-10).
- Deskman's `Layout` set (halves, thirds, quarters) and `GridTiler` were made for an ordinary display. On an ultrawide, a uniform grid wastes the center.
- The on-device model is good at picking a tool and a name, and bad at geometry (ADR-2610101046 §6). Placement math belongs in the domain.
- Hammerspoon no longer snaps windows that are moved by a program (`init.lua`, "no longer auto-snaps on resize/programmatic moves"), so Deskman's moves do not fight it.

## Decision

1. **Hammerspoon is the only source of the zones.** On load and on every layout change, `init.lua` writes `~/.hammerspoon/zones.json`: every layout (name, zones as 0…1 fractions, labels) and the name of the current one. Deskman reads that file and keeps no copy. If the file is missing or does not decode, Deskman says so in the outcome message and uses its built-in fallback layouts, so a failure is visible, never silent.
2. **A new driven port, `ZoneSource`**, implemented by a new adapter, `HammerspoonZonesAdapter` (adapters/secondary/hammerspoon). It reads a file. It runs no Lua and talks to no Hammerspoon process.
3. **The domain plans (`ZonePlanner`).** For the visible windows on the current desktop, on the frontmost window's display:
   - **Which layout:** the one that leaves the fewest windows unplaced, then covers the most screen with placed windows, then leaves the fewest zones empty, then the current Hammerspoon layout. A layout the person names wins outright.
   - **Who gets the room:** windows in priority order: a window the person named, then the apps focused most often in the learning history (ADR-2610101415), then front to back. The highest priority gets the largest zone.
   - **Least movement:** among zones of equal size, a window takes the free zone nearest its current center.
   - Windows beyond the zone count stay where they are, and the outcome names them.
4. **The model gets one tool, `smartArrange`**, with a layout name (or `auto`) and an optional app to give the most room. "Arrange my windows efficiently" and "set me up for coding" map to it. The menu gets **Smart Arrange** (⌘S), which runs `auto`.
5. **Smart Arrange can be undone**, like Arrange Like Usual, and earns no trust.

## Consequences

- Editing a zone in Hammerspoon changes Deskman's next Smart Arrange at once. There is one place to edit.
- `init.lua` gains about 20 lines, marked as Deskman's export. Without them, Deskman uses its fallback layouts and says so.
- A seventh tool costs context in a 4,096-token window. DeskmanEval must still pass.

## Implementation

- Gate: `scripts/gate.sh`, with tests in `Tests/DeskmanTests/ZonePlannerTests.swift` written before the code, and DeskmanEval for the tool.
- The gate's layer check gains the new adapter.

## References

- ADR-2610101046 (hexagon, tools), ADR-2610101415 (learning history), ADR-2610101429 (desktops).

## Amendment 2026-10-10 — measured changes, and the queue

**Shipped with this ADR:**
- Display size: a zone smaller than 500×400 pt counts against a layout; when no user layout fits, the built-in ones compete. An upright display turns the zones into rows.
- Most active: `FocusTracker` samples the frontmost app on every learning tick, for 30 minutes. The most active window takes the largest zone, and among equal zones the one nearest the display center. After 5 minutes of watching, windows with no focus in 30 minutes are minimized ("out of the way"); undo restores them.
- **No seventh tool.** A `smartArrange` tool cost the model "this window": "move this to my other screen" fell from 5/5 to 2/5 and 0/10 (DeskmanEval, 2026-10-10). `tileAllWindows` now runs Smart Arrange instead of a grid. Lost by voice: naming a layout and the app to make biggest; the menu and activity cover both.
- `listWindows` lists other-desktop windows last, under "Other desktops, focus only:". Mixed in, the model read "other screen" as "the window on desktop 2" (0/10 → 10/10).

**Queue, in order** (the user's requests, 2026-10-10; status as of 16:07 — 1 built (intents), 2 superseded by ADR-2610101542 (names, not roles), 3 built as ADR-2610101549, 4 built (browser beside terminal), 5 proposed as ADR-2610101607, 6 built as the desktop map):
1. **A hand move or resize is an intent.** A window the person moves or resizes, and Deskman did not, is pinned for 30 minutes: Smart Arrange keeps it and plans around it. A placement Deskman made never counts as learning evidence. Every Deskman move passes through one `WindowControl` decorator, so nothing can bypass the record.
2. **Roles by the model.** A `WindowClassifier` port (Foundation Models adapter) sorts each app into a role (editor, browser, terminal, chat, notes, other), cached per app. Smart Arrange then matches roles to Hammerspoon zone labels ("Editor", "Browser", "Terminal").
3. **What runs in a terminal.** The foreground process of each Warp, iTerm2 and Terminal window (process tree, libproc, no permission) becomes part of activity: a terminal running a dev server or an agent is active even when not in front.
4. **A new browser window goes beside the terminal.** Needs a window-created event from the Accessibility adapter (`AXObserver`).
5. **Tabs by activity.** Per-browser adapters over AppleScript (Chrome, Safari; Firefox has none), Automation permission. Its own ADR.
6. **A map of what was learned.** A view of the screen: green zones for learned habits, red for still learning. Clicking a red zone confirms it, as an accept.
