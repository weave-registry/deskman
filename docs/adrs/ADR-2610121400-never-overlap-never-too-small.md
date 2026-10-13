# ADR-2610121400: Never an overlap, never a window too small; a simpler menu

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "we should never have overlapping windows or windows that are too small" (Stream Deck over WhatsApp and off the screen; WhatsApp 633 pt wide); "whats app keeps minimizing"; "reevaluate all the deskman menu features, simplify based on where our product is today".

## Context

- `setFrame` accepted a window that kept a wider frame than it was given ("a window that refuses to shrink keeps its own size"). Nothing checked the result, so Stream Deck covered its neighbour.
- The minimum zone was 500 pt. Three Firefox windows at double width left 633 pt each to the other two.
- Keep Arranged parked WhatsApp as idle. Brought back, it changed the window set; the next arrange parked it again.
- The menu held two arrange buttons (Smart Arrange, Arrange Like Usual) and the learning features of the first release beside the model-driven ones. "Learn how I arrange windows" off also stopped Keep Arranged.

## Decision

1. **One minimum: 700 × 400 pt** (`ZonePlanner.minimumWidth`, `ModelLayout.minimumWidth`). The model's layout, Deskman's own (`ModelLayout.house`) and the preset zones never use a smaller place. When the windows do not fit, two share a column; when that does not fit either, the least active are moved out of the way.
2. **Read back after every arrange.** An app that kept a wider frame has a minimum: Deskman keeps it (`SmartArranger.learnRefusals`), plans once more around it (`LayoutRequest.floors`), and moves out of the way any window that still overlaps one placed before it or leaves the display. Undo puts every window back where it was before the first move.
3. **What the person brings back stays.** Windows that appeared since the last arrange are never idle and are placed first; the window in front is never moved out of the way.
4. **The menu:** Smart Arrange, Keep Arranged, Desktop Map, Open Deskman; then Drag to Snap, Apps Deskman Leaves Alone, Bound Projects (only once one is bound), a Learning submenu (learn switch, Forget My Activity). Removed: Arrange Like Usual (with its use case), What Deskman Learned (the map's Learned tab shows it). Unpin All moved to the map, where pins are shown. Keep Arranged depends on its own switch only.

## Consequences

- On a small screen fewer windows are arranged and more are minimized. That is the rule: fewer, usable windows.
- A minimum learned from an app is kept until Deskman quits.

## Implementation

- Gate: `scripts/gate.sh`, with `NoOverlapTests`, `HouseLayoutTests`, `aWindowYouBringBackIsNeverMinimizedAgain` and `pausingLearningDoesNotStopKeepArranged` written before the code. Tests that stated the 500 pt minimum were restated for 700.

## Amendment 2026-10-12 — the map is a tab

- The user: "can we just add desktop map as a tab on the main deskman window". The Deskman panel has one bar over two tabs, Ask and Map. The panel keeps its standard size, 540 × 460, for both; the map scales to it (the user: "scale the desktop to the standard deskman window size": a panel grown for the map drew its content past the glass, cut off at the top and right, and see-through). `DesktopMapWindow` is gone; `DesktopMapView` refreshes itself every 2 s while shown. Desktop Map ⌘M opens the panel on Map; `--diagnose-map` and `--diagnose-outline` drive the panel.
- `--diagnose-map` draws the content inside the glass: the glass draws blank offscreen, and native switches do not draw there either.

## Amendment 2026-10-12 — a browser is never stacked

- The user: "the browser is always in the middle and full vertical height". The model had stacked two Firefox windows in the middle column, 705 pt each, and `frames` accepted it.
- `ModelLayout.frames`: a browser in a stacked column gets a full-height column of its own. `centerBrowser` centers the most active browser (first in priority), not the first column with one. `house` pairs only windows that are not browsers.
- Tests: `BrowserColumnTests`, written before the code. `aStackTooShortToWorkInIsRejected` was restated with apps that are not browsers.

## Amendment 2026-10-12 — focus is tracked per window

- The user asked for it: Deskman knew only that "Firefox" was in front, not which of three Firefox windows, so the middle column went to whichever came first.
- `FocusTracker` records the window in front with each sample; `windowActivity()` counts per window over 30 minutes. Smart Arrange ranks by the window's own count first, then its app's. The most used browser window is therefore the first browser, which `centerBrowser` puts in the middle; the model is told each window's own count.
- In memory only, like the app counts. Tests: `WindowFocusTests`, written before the code.

## Amendment 2026-10-12 — Deskman never minimizes

- The user: "we should never minimize an app in deskman". Deskman minimized inactive windows (on a click), windows with no room, windows still overlapping after the read-back, and a bound project's other windows.
- All four are gone. Inactive parking is deleted from `SmartArranger` (with `FocusTracker.canJudgeIdle` and the unused `terminals` it needed); `Follow.minimize` is deleted; Undo no longer restores minimized windows, since there are none.
- The trade-off, stated: a window with no room at a usable size is left where it was, and may sit behind arranged ones. "No overlap" and "never too small" hold for every window Deskman places; the message names any window left alone ("No room for …; left where it is"). A window the first pass moved and the final plan has no room for is put back where it was.
- An explicit request to the assistant ("minimize Slack") still minimizes: that is the person's act.
- Tests: `NeverMinimizeTests`, written before the code. Tests that stated parking were restated for this rule; `undoAlsoBringsBackTheWindowsMovedOutOfTheWay` was removed with the feature it tested.

## Amendment 2026-10-12 — two at most per column, everywhere; an app settling is not a pin

- The user: "should never try and squeeze 3 windows in a column but you still are". `ModelLayout.maxStack` held for the model's layout and Deskman's own, but not for `ZoneGenerator`, which stacked as many as fit tall (three in 1410 pt). It ran when windows kept in place left a strip Deskman's own layout could not fill. Now `ZoneGenerator` uses the same limit. `NeverThreeStackedTests` checks every window count from 1 to 12 on six display shapes.
- Why the strip: three windows were pinned 3 s after a Smart Arrange, right after a restart. An app settling after Deskman's move (iTerm2 snaps to whole text cells; Firefox lands late) was taken for the person's. Within 10 s of Deskman's move, a window within 48 pt per edge of Deskman's frame is the app settling, not a pin. A drag still pins. Tests: `anAppSettlingNearDeskmansPlaceIsNotAPin`, `aRealDragSoonAfterDeskmansMoveIsStillAPin`.
