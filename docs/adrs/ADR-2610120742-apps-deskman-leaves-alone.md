# ADR-2610120742: Apps Deskman leaves alone, and a switch for drag-to-snap

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "build the floating apps rule and drag-to-snap switch". These are two of the Hammerspoon features that ADR-2610101523 did not carry over: Ctrl+Alt+F (an app that never snaps) and Ctrl+Alt+D (drag-to-snap on or off).

## Context

- Hammerspoon kept a list of "floating" apps (Finder, System Settings, Calculator, Preview, 1Password, Raycast, Alfred, Spotlight, …) and never drag-snapped them. Ctrl+Alt+F added or removed the front app.
- Deskman pins a window the person places for 30 minutes (`IntentLog`). That is an intent about one window for a while, not a rule about an app. Smart Arrange, learned suggestions and "a new browser beside the terminal" move a Calculator window again after the pin runs out.
- Drag-to-snap has no off switch: only Option, held on each drag.
- Both settings must last across a restart, and must survive "Forget My Activity", which erases what Deskman learned, not what the person told it.

## Decision

1. **`Preferences` (domain)**: the floating apps and whether drag-to-snap is on. The defaults are Hammerspoon's list and on. App names match without regard to case. Fields missing from a saved file take their defaults, so later fields decode from older files.
2. **`PreferenceStore` (driven port)**: load and save. `FilePreferenceStore` keeps `preferences.json` in the activity-store folder, owner-only. `eraseAll` does not touch it. A file that cannot be read is reported, never replaced in silence: Deskman runs on the defaults and says so in the menu, and the next change writes a good file.
3. **`Settings` (use case) behind `SettingsPort` (driving port)**: set or toggle a floating app, toggle the front window's app, set drag-to-snap. A save that fails keeps the change for this run and says it will be lost.
4. **What "leave alone" means**: Deskman never moves a floating app's window on its own initiative.
   - Smart Arrange (menu and the model's tool) neither moves, parks, nor plans around it. It is not kept clear: a small Calculator does not shrink the zones.
   - Learned suggestions, automatic ones and "Arrange Like Usual" leave it out.
   - A new floating browser window is not put beside the terminal.
   - Drag-to-snap does not snap it.
   - A request that names the window is still obeyed: a snap hotkey, or "put Finder on the left". The person asked for that window.
5. **Drag-to-snap off**: no overlay and no snap. The hotkeys still work.
6. **Keys and menu**: Ctrl+Alt+F toggles the front app, Ctrl+Alt+D toggles drag-to-snap, the keys Hammerspoon used. The menu has a "Drag to Snap" toggle and an "Apps Deskman Leaves Alone" submenu: the list, each one a checkmark that removes it, and an item for the front app.

## Consequences

- Hammerspoon's floating list carries over by default, with no import step.
- While Hammerspoon runs, it holds the same Ctrl+Alt keys. Deskman reports how many of its keys it got (`--diagnose`).

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/FloatingTests.swift` written before the code.

## Amendment 2026-10-12 — built

- 23 tests in `FloatingTests.swift`. One caught a real bug before it shipped: adding "mail" when "Mail" was on the list replaced the spelling.
- `Settings` (use case) is given to `SmartArranger`, `WindowService`, `ActivityService` and `SnapService` by the composition root. `FilePreferenceStore` lives in the activity-store adapter.
- Live check: `--diagnose` prints `settingsKeys=2/2` and the list; `--diagnose-menu` shows "Drag to Snap ⌃⌥D" and "Apps Deskman Leaves Alone".
- Hammerspoon, while it runs, binds the same Ctrl+Alt keys, and Carbon still gave Deskman both. Which app gets a key press while both run was not tested. Quit Hammerspoon.
