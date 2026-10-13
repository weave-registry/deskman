# ADR-2610120830: The model binds a project's windows together

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "can you see the window titles when they say Atlas Claude Session and Atlas Portal — we need to learn this and bind the two windows together", then "we should be leveraging the local apple llm model for this". Asked what binding does, the user chose all four: arrange side by side, focus together, move together, minimize together. Asked who decides: "suggest, then I confirm".

## Context

- The activity log shows Firefox "Atlas Portal" in the center third, four times, beside an iTerm2 window in the left third whose title is "tuios". "Atlas Claude Session" is the model's name for that terminal (ADR-2610101542): it comes from the `claude` job running in the atlas folder (ADR-2610101549). No title says so; only the model's reading of the title and the job does.
- `WindowIDs` do not last across a restart. A binding must be stored as something that does: the project.
- The model already reads every window's title, folder and terminal job, once per change, to name it. The project is one more field of the same answer, not a second call.

## Decision

1. **The namer returns a project with each name.** `WindowNamer.names(for:)` returns `NamedWindow(name, project)`. The project is one or two lowercase words ("atlas"), or nil when the model sees none. `WindowNames` keeps both, keyed as before.
2. **A binding is a project the person confirmed**, stored in `Preferences.boundProjects`. A project the person declined goes in `declinedProjects` and is not offered again. Both survive "Forget My Activity" (ADR-2610120742).
3. **The suggestion** (domain `Bindings.candidate`): a project the model gave to two or more visible windows on this desktop, from two or more apps, neither bound nor declined. The toast: "Bind Atlas Portal and Atlas Claude Session? They look like one project: atlas." Bind / Not now. "Not now" declines.
4. **Bound windows** are the windows whose project is bound, on any desktop, minimized or not. What they do:
   - **Side by side.** Smart Arrange puts a group in consecutive zones, at the place of its most active member; a group with one active member is active as a whole. A snap key or a drag that places one member puts the others in the zone beside it, on the same display.
   - **Focus together.** When one comes to the front, the others are raised, then the one the person chose is focused again.
   - **Move together.** When one moves to another display, by hand or by Deskman, the others follow, at the same relative place.
   - **Minimize together.** When one is minimized or restored, the others are too.
5. **`BindingService` (use case)** watches every second (`observe`): the front window, minimized state and display of each bound window. The rules are the domain's (`Bindings.follow`), so a follow cannot trigger itself: a partner already where its lead is gets no action.
6. **The map's Now tab** shows bound windows with a 🔗 and the project. The menu has a "Bound Projects" submenu that lists the bindings; a click unbinds one.
7. A floating app (ADR-2610120742) is never bound: Deskman leaves it alone.

## Consequences

- One AX sweep per second while any project is bound. With none bound, `observe` reads nothing.
- Focus together flickers once: macOS activates the partner's app, then the lead's.
- The project is the model's guess. A wrong guess costs one "Not now".

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/BindingTests.swift` written before the code.

## Amendment 2026-10-12 — built

- Tests: `BindingTests.swift` (rules, service, Smart Arrange order, snap partner), written before the code. Gate: 278 tests.
- The real model: `swift run DeskmanEval --projects` gives it the Atlas windows as the activity log recorded them (iTerm2 "tuios" running `claude in atlas`, from `/Users/me/app/atlas`; Firefox "Atlas Portal") with decoys. 3 of 3 runs: atlas for the pair, deskman for the Deskman pair, none for Mail.
- The same check found a regression: with a project field, the model left the project out of the name, and both terminals came back "Claude Code". `WindowNames` now puts the project in front of a name that lacks it ("Atlas Claude Code").
- Not checked live: the toast, focus, move and minimize following on the real screen. A copy started from a shell has no Accessibility permission, so it sees no windows.
