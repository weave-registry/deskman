# ADR-2610101429: Deskman sees the windows on every desktop

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** The user asked: "I need to have deskman aware of all windows on all desktops."
**Amends:** ADR-2610101415, Context bullet 4 ("all windows" meant the current Space only).

## Context

- The Accessibility API (`kAXWindowsAttribute`) returns an app's windows on the current Space (desktop) only. Deskman could not see, name, or switch to a window on desktop 2.
- `CGWindowListCopyWindowInfo` without `.optionOnScreenOnly` returns every window on every Space, front to back, with its owner, bounds and `CGWindowID`. It gives no Space number and no way to move the window. Window names need Screen Recording permission, which Deskman does not ask for.
- A window on another desktop has a frame in the same coordinates as the current desktop. If it joins the list without a mark, the tiler and the learner treat it as a window on screen and try to place it. That is worse than not seeing it.
- Which Space holds a window is known only through private SkyLight calls (`CGSCopyManagedDisplaySpaces`, `CGSCopySpacesForWindows`). yabai, AltTab and Hammerspoon use them. They read; they change nothing.
- The link from an `AXUIElement` to its `CGWindowID` is the private `_AXUIElementGetWindow`, used by Rectangle and Hammerspoon. It also gives Deskman a stable window id for the first time.

## Decision

1. **The domain says where a window lives.** `WindowSnapshot` gains `desktop: Int?` (the Mission Control number, 1-based, counted across displays; nil when macOS does not say) and `isOnCurrentDesktop: Bool`. `isVisible` is "not minimized and on the current desktop".
2. **The port's list is every window on every desktop**: current-desktop windows first, front to back, then the others by desktop number.
3. **Only focus reaches another desktop.** `WindowService` refuses arrange, move-to-display, tile and every action except focus on a window that is not on the current desktop, and says which desktop it is on. Focus activates the app, and macOS switches to a desktop where it has a window.
4. **Learning sees the current desktop only.** `DeskSnapshot` and `Learner` ignore windows on other desktops, so a placement is never learned from a frame that is not on screen. The stored record shape does not change.
5. **The matcher prefers what is in front of you.** For equal scores: the frontmost window, then a visible one, then a minimized one, then one on another desktop.
6. **The private calls stay in the Accessibility adapter**, declared with `@_silgen_name`. If SkyLight returns nothing, the adapter logs it once and reports Accessibility windows only, with `desktop` nil. The log is the loud failure: the list is honest about what it holds, because nothing it holds is marked off-desktop by guess.
7. **Window ids are `w<CGWindowID>`.** A window keeps its id across reads and across desktop switches. An element with no `CGWindowID` falls back to a counter id, `a<n>`.

## Consequences

- The model can answer "which desktop is Slack on" and "switch to Slack" for a window it could not see before.
- Off-desktop windows have no title unless Deskman saw the window on the current desktop earlier (the adapter remembers the last title per `CGWindowID`) or the user grants Screen Recording.
- Focus on an off-desktop window of an app that also has a window on the current desktop activates the app without a desktop switch. The outcome message says "Switched to <app>", which is true; it may not be the exact window.
- A private symbol can change in a macOS release. The cost then is the fallback in Decision 6, not a crash: `@_silgen_name` binds at link time against symbols macOS has kept since 10.x.

## Implementation

- Gate: `scripts/gate.sh`, with new tests in `Tests/DeskmanTests/DesktopTests.swift`, written before the code.
- Left for later: move or arrange a window on another desktop (switch, wait for its element, act, switch back). Tracked in this ADR until it has a workplan.

## References

- ADR-2610101046 (the hexagon, the gate). ADR-2610101415 (learning).
