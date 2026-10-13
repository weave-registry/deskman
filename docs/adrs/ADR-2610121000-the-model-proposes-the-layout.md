# ADR-2610121000: The model proposes the layout; Deskman makes it gap-free

**Status:** Superseded by ADR-2610121700 (Smart Arrange fills your grid). The model-layout code was removed on 2026-10-12.
**Date:** 2026-10-12
**Drivers:** The user: "the zones should react to the window sizes to maximize the view, we should avoid too many gaps; if there are more than two windows open, the model should be asked for the best layout; can you show me a debug of how the model responds".

## Context

- Smart Arrange never asked the model. `ZoneGenerator` sizes columns by activity alone. It knows neither what a window holds (a browser page wants width, a shell does not) nor its present size.
- The newest activity record (2026-10-12) holds three windows on the 5120×1440 display: iTerm2 "tuios" in the left third, Firefox in the center third, a second iTerm2 in a quarter-width, half-height spot on the right. A third of the screen is empty. Thirds and quarters are Hammerspoon's zones, and Hammerspoon was still running. Deskman's rules alone would not leave that gap, but they would still ignore content and size.
- A seventh assistant tool cost the model "this window" (ADR-2610101501 amendment). This is not a tool: it is a fresh session, as naming is (ADR-2610101542), and the assistant never sees it.
- A 3B model asked for free rectangles will overlap them and leave gaps. Asked for a structure, it can be checked.

## Decision

1. **`LayoutAdvisor` (driven port), `FoundationModelsLayoutAdvisor` (adapter).** Given the area and the active windows, each with its app, the model's name and project, its present size and its focus count, the model returns **columns**, left to right: a width in percent and the windows stacked in it, top to bottom, and a one-sentence reason. The prompt asks for wide columns for wide content, narrow ones for terminals and chat, a project's windows side by side, and the main window in the center of an ultrawide.
2. **`ModelLayout.frames` (domain) makes the answer exact.** The widths are scaled to fill the area; the last column takes the rest; each column's windows split its height evenly. There can be no gap and no overlap. It rejects an answer, with the reason, when a window is missing, repeated or unknown, when a column is narrower than 500 pt, or when a stacked window is shorter than 400 pt. An upright display turns columns into rows.
3. **When it is used.** Three or more active windows, and no window named for the most room. The model is asked in the background, on the learning tick, when the set of active windows or the area changes, never in a click's path. Smart Arrange uses the answer when it is for the windows on screen now. Otherwise, or when it was rejected, Deskman's rules arrange, and the outcome and the map say why.
4. **The debug.** Every request keeps its prompt, the model's raw answer, the seconds it took, and what Deskman did with it. `--diagnose-layout` prints the last one with a picture of the zones; `swift run DeskmanEval --layout` sends the user's three windows from the activity record to the real model three times. The map's Smart Arrange tab names the source of the plan, with the model's reason.

## Consequences

- With three or more windows, the plan follows the model's reading of content, not activity alone.
- The first Smart Arrange after the windows change may use the rules, until the model has answered (a second or two).
- Apps that refuse a size (a terminal rounding to its character grid) can still leave a few points of gap. Every move is already read back; that is not changed here.

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/ModelLayoutTests.swift` written before the code; `swift run DeskmanEval --layout` for the real model.

## Amendment 2026-10-12 — what the real model did, and what changed because of it

`swift run DeskmanEval --layout [4]` runs the real namer and advisor on the user's windows. Each finding below changed the design:

1. **Percent widths:** every column "width 100", then "250, 250, 200". Arithmetic is not the model's job. Decision 2 already scaled them, so the result was gap-free, but the widths were arbitrary.
2. **A size word per column:** "wide, normal, narrow" by position, giving the terminal the most room and the browser less. The reason it wrote contradicted its own answer.
3. **What each window shows** (web page, document, code editor, design, terminal, chat, notes, other), with Deskman setting the room: right in 6 of 6 runs. The model keeps the order and the stacking. This is what shipped.
4. **0-based numbers** in one 4-window run: rejected, then made a safe repair when the numbers are each window exactly once (`ModelLayout.frames`).
5. **The namer copied its examples** into names and projects ("deskman", then "orbit", then "Safari: Pull Request #12"), and once gave Firefox the terminal's name, by order. Answers now carry their window number, and the namer prompt has no example titles.

Still open: the model stacks a web page with an editor though told not to. The result is gap-free and usable, so it is not rejected.

## Amendment 2026-10-12 — the debug told the user something false

- The user ran `Deskman --diagnose-layout` from a terminal and got "There are no windows to arrange". The binary had the terminal's permissions, and the terminal has no Accessibility permission, so the window list was empty. The message named the wrong cause. This is the "gate that degrades silently" lesson in CLAUDE.md.
- Now: Smart Arrange without the permission says so (test `withoutPermissionItSaysSoInsteadOfNoWindows`). Every diagnose that needs windows prints `FAILED:` with the cause and exits 1. `scripts/diagnose.sh <what>` runs the diagnose inside the app with `open`, with the app's own permission, and returns the output through a file.
- Live run through the app, 4 windows: the answer is gap-free (1267 + 1267 + 2534 = 5068 pt). Still wrong: the model's reason says Firefox is "in the middle" when its own columns put it on the right; and, among three iTerm2 windows, a job goes to a window by the model's guess, because Deskman cannot tell which iTerm2 window runs it (the gap ADR-2610101607 would close).
- A home folder is no longer a project: `TerminalJob.folderName` is nil for `/Users/<name>` (the model made "gary" a project from "tuios in gary").

## Amendment 2026-10-12 — at most two windows in a column

- The user: "we should not stack three apps in one column, that would make it hard to use". The live answer was `[1, 2, 3] [4]`: three terminals 470 pt tall, which the 400 pt minimum allowed.
- `ModelLayout.maxStack = 2`. A taller column is split in place, in the model's order, each part as wide as the column was; the answer is kept, not rejected. The prompt says "never more than two windows in one column". Test: `aColumnOfThreeIsSplitSoNoColumnStacksMoreThanTwo`.
- Two live runs after the change: the model itself answered `[1, 2] [3] [4]`.

## Amendment 2026-10-12 — a web browser always goes in the center

- The user: "web browsers should be always in the center". The model had been told to put the widest content in the middle and did not; three times its reason said "Firefox in the middle" while its columns put Firefox on the right.
- So it is a rule, not a hint: `ModelLayout.centerBrowser` moves the browser's column to the place whose middle is nearest the area's middle; the other columns keep the model's order. With two columns there is no center, so a stacked column is split, one window on each side. A browser is found by app name (`Browsers`), not by the model. The prompt says it too.
- Live, the first run after the change: the model answered `[1] [2] [3]` with Firefox last, "to avoid cluttering the middle column". Deskman placed it `[1] [3] [2]`, Firefox in the center.
