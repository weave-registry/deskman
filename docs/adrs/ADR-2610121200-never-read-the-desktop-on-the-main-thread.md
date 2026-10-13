# ADR-2610121200: Deskman never reads the desktop on its main thread

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** With Keep Arranged on (ADR-2610121130), the user: "this is freezing", "stop the freezing", "we cannot have a blocking operation, we need to do the analysis in the background".

## Context

- `AccessibilityWindowControl.windows()` read every window of every app, then asked the window server and SkyLight where each one lives. All of it ran on the main thread, where the menu, the keys, the map and drag-to-snap run.
- An Accessibility call to an app that is busy waits up to macOS's default timeout of about 6 s. One slow app froze Deskman.
- Keep Arranged added a full read every second; bound windows (ADR-2610120830) another; the learning tick, naming and the layout advice more.
- Deskman was killed to stop the freeze; Keep Arranged was turned off in `preferences.json` until this is fixed.

## Decision

1. **The read runs on a background queue** (`DesktopRead.read`): Accessibility, the window server and Spaces. The main thread only gives each window its stable ID, which is local work, no message to another app.
2. **`windows()` answers at once** from the newest background read (at most about a second old) and starts the next one if none is running. Only the very first call, before any read has finished, reads on the calling thread.
3. **Deskman's own moves update that copy at once**: a frame Deskman set, a window it minimized or restored. The next plan does not see the old place.
4. **One window, fresh: `frame(of:)`** on `WindowControl`. Drag-to-snap reads the grabbed window's frame with it at mouse-down and while confirming the drag; a second-old frame would make a click look like a drag (the Firefox incident, ADR-2610101523).
5. **Every Accessibility call is limited to 0.5 s**, set once for the process (`AXUIElementSetMessagingTimeout` on the system-wide element). A hung app costs at most that.
6. **`--diagnose-speed`** measures it: the background read, and how long `windows()` holds the main thread. The gate for this ADR: `windows()` on the main thread under 5 ms after the first read.

## Consequences

- The menu, keys and map stay responsive whatever the other apps do.
- Plans may use frames up to a second old. Moves are read back as before, so a stale frame never becomes a wrong report.

## Implementation

- Gate: `scripts/gate.sh`, plus `scripts/diagnose.sh speed`.

## Amendment 2026-10-12 — built, and the second cause

- Measured (`scripts/diagnose.sh speed`, 6 windows): the background read takes 11 ms; `windows()` holds the main thread 0.0 ms over 20 calls. The first read, at start-up only, 72 ms.
- 72 ms once a second is not a freeze on its own. The read on the main thread was a risk with a slow app; it was probably not the whole freeze.
- The second cause was the debug itself: `--diagnose-menu` opened Deskman's own menu through Accessibility. Calls to one's own app run on the calling thread, not through the system: from the main thread the press waited for itself (a 25 s hang, its menu open on screen, its mouse event tap and hotkeys not answered); from a background thread SwiftUI built the menu off the main thread and Swift's isolation check trapped (exit 133, `_dispatch_assert_queue_fail` in `LearningMenu.body`). Now it reads the running Deskman's menu, another process, which answers on its own main thread.
- A diagnose copy (`--diagnose-*`) now sets up no hotkeys, no mouse event tap and no cards: it only looks, and a hung one cannot hold the mouse.
- Still on the main thread: `setFrame` reads a move back, up to 0.3 s per window that is slow to land (the Firefox fix), and the terminal job scan, 8 ms.
- Keep Arranged was turned off in `preferences.json` when Deskman was stopped. It is the user's to turn back on.

## Amendment 2026-10-12 — the old read pinned Deskman's own moves

- A background read that started before Deskman moved a window finished after the move. It showed the window at its old place; the next read showed the new one. `IntentLog` gave the first change to Deskman and took the second for the person's: four windows Smart Arrange had placed were pinned, and the next arrange worked around them (overlaps, an empty strip).
- The adapter: a read keeps Deskman's own change for a window changed after the read started.
- `IntentLog`: a window back at its place from before Deskman's move, within 10 s, is an old read and no change; a window at the frame Deskman set is Deskman's, however many reads it took to show it.
- "Unpin All Windows" in the menu: no wrong pin holds a window for 30 minutes again.
- Test: `aReadOlderThanDeskmansMoveDoesNotPinTheWindow`, written before the code.
