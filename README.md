# Deskman

Tell your Mac where to put its windows, in plain words. Apple's on-device model
understands the request; Deskman moves the windows. Nothing leaves your Mac.

> "Safari and Notes side by side" · "put this window on the left third" ·
> "move this to my other screen" · "open Calendar on the right half"

## Requirements

- macOS 26 or later on Apple silicon, with **Apple Intelligence turned on**
  (System Settings → Apple Intelligence & Siri).
- Xcode 26 or later (for the Swift 6.2 toolchain).

## Start it

```bash
scripts/make-signing-identity.sh   # once: a local signing certificate
scripts/build-app.sh               # builds build/Deskman.app
open build/Deskman.app
```

1. Deskman opens a floating panel and puts an icon in the menu bar.
2. Click **Allow…** in the panel. Turn on Deskman in
   System Settings → Privacy & Security → Accessibility.
3. Press **⌃⌥Space** from any app to show or hide the panel. Type a request. Press Return.

The panel takes your typing without taking focus from your app, so "this window"
means the window you were using. Press Esc to hide the panel.

macOS remembers the Accessibility permission by the app's signature. The local
certificate keeps that signature the same on every rebuild. Without it the build is
signed ad hoc, gets a new signature each time, and loses the permission.

## What it can do

**Ask in words** (⌃⌥Space):

| Ask for | Tool the model calls |
|---|---|
| halves, quarters, thirds, two-thirds, maximize, center | `arrangeWindow` |
| send a window to the next display | `arrangeWindow` with `nextDisplay` |
| focus, minimize, restore, close, full screen, hide app | `windowAction` |
| side by side, or a grid, of named apps | `tileWindows` |
| "tile all my windows", "organize my windows": Smart Arrange | `tileAllWindows` |
| start an app (and then place it) | `openApp` |
| "what's open?" | `listWindows` |

A window can be named by its app, its title, or the name the model gave it
("the deskman session"). Windows on other desktops are listed; only focus reaches them.

**From the menu bar icon:**

| Item | What it does |
|---|---|
| Smart Arrange ⌘S | Fills your grid, and only your grid: zone 1 over 2, 3 in the middle, 4 over 5 (the snap zones). A window already in a zone stays. Zone 3 goes to the browser you use most; a browser takes a whole column, never stacked; a window alone in a side column gets its full height. Windows with no free zone are left where they are, never minimized. Windows you placed by hand, and the one you are working in, are kept. Undo from the card. |
| Keep Arranged | Smart Arrange each time a window opens, closes, minimizes or comes back, or you switch desktop. It never moves the window you are working in; that one gets its place when you move on. During a Zoom, Teams, Webex or FaceTime meeting it changes nothing. |
| Desktop Map ⌘M | Opens the Deskman panel on its Map tab: your screen to scale, windows now (with names and what runs in terminals), the Smart Arrange preview with Apply, and **What Deskman Knows**: your habits, the windows you used most in the last 30 minutes, which zone of your grid each window holds, what Keep Arranged is doing, and your bound projects. Unpin All is here, where 📌 pins show. |
| What Deskman Knows ⌘K | Opens the panel straight on the map's What Deskman Knows tab: your habits by zone, the windows you used most, your grid, Keep Arranged's state, bound projects. |
| Open Decision Log ⌘L | Why Deskman did what it did, one line per decision: what started an arrange, the ranking, what was kept and why, which layout ran, each move, every pin and why. The file is `~/Library/Logs/Deskman/decisions.log`; it opens in Console. |
| Open Deskman | The panel, on its Ask tab: tell Deskman what to do in words. |
| Drag to Snap, Apps Deskman Leaves Alone, Bound Projects, Learning | The switches. Bound Projects shows once a project is bound. |

**Without asking:**

- **Snap hotkeys:** ⌃⌘1…5 put the front window in a snap zone; ⌃⌘F fills the screen.
- **Drag to snap:** drag a window by its title bar and drop it on a zone. Hold ⌥ to drop it freely.
- **Learning:** settled arrangements are recorded; a habit seen 3 times is suggested; accepted 3 times, it is applied by itself.
- **A new browser window goes beside your terminal.**
- **A window you move or resize stays put** for 30 minutes: Smart Arrange works around it.
- **Names:** the on-device model names windows by what they are for, using titles, documents and what runs in each terminal.

Deskman replaces a Hammerspoon zone manager. Run one or the other: both register ⌃⌘1…5.

## Architecture

Hexagonal, following the [hexa](https://git.local/gary/hexa) practices. Each layer is
its own SwiftPM target, so the compiler refuses an import that crosses a boundary.

```
Sources/
  domain/            geometry, GridPlanner (your zones), ZoneGenerator, ZonePlanner, Learner, TargetMatcher,
                     TerminalMatcher, DesktopMap — pure value types and rules
  ports/             driven: WindowControl, Assistant, ActivityStore, TimeSource,
                     WindowNamer, TerminalActivity
                     driving: WindowCommands, DeskmanPort, ActivityPort, SnapPort
  usecases/          WindowService, DeskmanService, ActivityService, SmartArranger,
                     SnapService, IntentLog, FocusTracker, WindowNames, TerminalWatch
  adapters/secondary/accessibility/      windows on every desktop (AX + SkyLight)
  adapters/secondary/foundation-models/  the on-device model: six tools, and the window namer
  adapters/secondary/activity-store/     learned arrangements, owner-only files
  adapters/secondary/processes/          what runs in terminals (libproc; names and folders, never arguments)
  adapters/primary/ui/                   panel, map, suggestion card, hotkeys, drag-to-snap
  app/                                   composition root — the only code that names adapters
```

The decisions and their reasons are in [docs/adrs](docs/adrs/), from
[ADR-2610101046](docs/adrs/ADR-2610101046-deskman-is-a-hexagonal-swift-app.md) on.

## Checks you can run

```bash
open -W --stdout /dev/stdout build/Deskman.app --args --diagnose-menu       # the menu's items
open -W --stdout /dev/stdout build/Deskman.app --args --diagnose-arrange    # what Smart Arrange would do
open -W --stdout /dev/stdout build/Deskman.app --args --diagnose-names      # the model's window names
open -W --stdout /dev/stdout build/Deskman.app --args --diagnose-terminals  # terminal jobs and their windows
open -W build/Deskman.app --args --diagnose-map /tmp/map.png "Smart Arrange" # a picture of the map
swift run DeskmanEval                                                       # the model picks the right tool
```

## The gate

```bash
scripts/gate.sh
```

Exits 0 only when every layer imports only what it may, no code outside the model
adapter names a model, the build passes with explicit import checking, and the
tests pass. Zero tests counts as a failure.
