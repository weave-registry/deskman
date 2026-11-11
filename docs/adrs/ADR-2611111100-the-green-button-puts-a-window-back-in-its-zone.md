# ADR-2611111100: The green button puts a window back in its zone

**Status:** Accepted
**Date:** 2026-11-11
**Drivers:** The user: "if windows are fully overlapping e.g. full vertical, when clicking the full screen should put
it back into the zone". The click meant is the green title-bar button.

## Context

- A window that grows past its zone (a zoom, a drag of its edge, an app opening at full height) covers its
  neighbours. The way out the person reaches for is the green button.
- For most apps the green button is the native full-screen button: a click sends the window to a Space of its own.
  Option-click zooms. Neither puts the window back where it was in the grid.
- Deskman's mouse taps only listen. A listening tap sees the click after macOS has acted on it.

## Decision

1. **`ZoneReturn`** (domain). A window's *places* are the snap zones of its display, plus each side column (two zones
   stacked one on top of the other, as Smart Arrange uses for a window alone in a column). A window is *out of its
   zone* when its frame is within 48 pt of no place, and it covers another visible window Deskman arranges by more
   than a tenth of the smaller one. A window of an app Deskman leaves alone (Preview, Finder) floats over the grid by
   design: covering it is not growing over a neighbour. (2026-11-11: 32 pt and counting every window put a ring on
   iTerm2, which sat in its column 35 pt short, over a Preview window.) Its target is the place it last sat in, if any. Otherwise it is the zone it covers most.
2. **`SnapService`** (`SnapPort`). Each second it notes the place every visible window sits in. On a click it
   *claims* the click only when all of these hold:
   - the switch is on;
   - the click is on the green button of the front-most window under the mouse;
   - that window is out of its zone, by its frame read fresh;
   - the window is not in an app Deskman leaves alone, and no meeting is on.
   The window then goes to its target, as a snap does: the person's choice, pinned, through the gateway.
3. **`GreenButtonWatch`** (UI adapter). An *active* event tap on the left button. A claimed click is taken, down and
   up, so macOS never sees it, and the window is moved after the tap returns. Every other click passes untouched,
   as does any click with Option held. An Accessibility call made while the tap holds a click has a 0.15 s
   timeout, so a hung app cannot hold the mouse.
4. **`WindowControl.greenButtonFrame(of:)`**: the button's frame, read from that one window. It is nil for a window in
   native full screen: clicking the green button there leaves full screen, as macOS does.
5. **A green ring** is drawn around every green button in view whose click Deskman would take, refreshed each second.
   In view is judged by the window server's order and frames at that moment, not the list, which may be a second old
   (2026-11-11: an old order put a ring over Mail's sidebar, on Slack's covered button). Every ring hides on a click.
   It ignores the mouse, so a click on it reaches the button. (The user, 2026-11-11: "I don't see where the green
   button is telling me that there's an overlapping window.")
6. **Green Button Puts Window Back in Its Zone** is in the menu. It is saved with the preferences and on by default.

## Consequences

- A window in its zone, or covering nothing, keeps the green button's usual meaning.
- It is the first tap that takes clicks away from other apps. The pre-check is cached frames and rect arithmetic;
  only a click in a window's top-left corner reaches Accessibility.

## Implementation

- Gate: `scripts/gate.sh`, with `ZoneReturnTests` and `GreenButtonTests` written before the code.
