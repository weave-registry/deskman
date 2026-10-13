# ADR-2610101542: The on-device model names your windows

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** The user: "there are too many things going on … i need AI to help me name the windows so we can find things."

## Context

- Window titles say little: two iTerm2 windows are both "Claude Code"; a browser says "Problem loading page". The map and the list show app and title, so the person cannot tell windows apart.
- The on-device model can read an app and title and say what the window is for, in a few words. It is slow (about a second) and may be unavailable, so it cannot sit in the path of a command.

## Decision

1. **A driven port, `WindowNamer`**: given windows (app and title), return a short name for each, 2–5 words, saying what the window is for. Implemented by `FoundationModelsNamer` in the Foundation Models adapter, the only place that may name a model.
2. **A use case, `WindowNames`**, keeps the names in memory, keyed by app and title. `refresh` asks the namer only for windows it has not named, at most 12 at a time; a changed title is a new key. Reads are synchronous and never wait for the model.
3. **When the model fails or is unavailable**, a window has no AI name and shows its app and title, as before. The failure is kept in `WindowNames.lastError` and shown in the map's caption. Nothing pretends to be a name.
4. **Names are used to find windows.** `TargetMatcher` scores a match on the name, so "the deskman terminal" finds the window named "Deskman Claude session". `listWindows` shows the name. The map shows the name first, the app second.
5. The learning timer refreshes names every tick; only new windows reach the model.

## Consequences

- Each new window costs one short model call, in the background.
- Names live for the session only. They come back after a restart as the model renames windows.

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/WindowNamesTests.swift` written before the code; `--diagnose-names` prints the real names the model gives.
