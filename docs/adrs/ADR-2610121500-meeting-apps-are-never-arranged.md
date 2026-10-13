# ADR-2610121500: Meeting apps are never arranged; a meeting stops Keep Arranged

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "when zoom is active it hides all other windows?"; "We should probably treat zoom completely differently, it should be given its own desktop and autoarrange turned off because if we are sharing an app we dont want to change anything".

## Context

- The trace, 10:04: "Could not move: Zoom (AXError -25202)", then "Moved 1 window out of the way: Slack". Zoom would not go where it was put (one window replaced, its meeting window keeping its own shape); the overlap check then minimized the windows Zoom covered.
- During a screen share every move Deskman makes is seen by everyone in the meeting.
- macOS has no supported way for an app to move a window to another desktop; the tools that do need System Integrity Protection off.

## Decision

1. **`MeetingApps`** (domain): Zoom, Teams, Webex, FaceTime. Their windows are never moved, resized or minimized, by Keep Arranged or Smart Arrange. Other windows are planned around them, as around a pinned window, so none covers them.
2. **A meeting stops Keep Arranged entirely**: while a meeting app has a window whose title says meeting, webinar, share, sharing or call, nothing is arranged on any desktop. The trace says "paused: a meeting is on". The baseline stays; what changed meanwhile is arranged once the meeting ends.
3. **Its own desktop**: Zoom's own setting, "Enter full screen automatically when starting or joining a meeting", puts each meeting on its own desktop. Deskman leaves other desktops alone already.

## Consequences

- A meeting is recognized by window titles. Zoom's are known; a Teams meeting window is named after the meeting and is recognized only when its title has one of the words.
- A large Zoom window leaves less room; windows with no room at a usable size are moved out of the way by a Smart Arrange click, never by Keep Arranged during a meeting.

## Implementation

- Gate: `scripts/gate.sh`, with `MeetingTests` written before the code. Tests that used Zoom as an ordinary app now use WhatsApp and Recorder.

## Amendment 2026-10-12 — nothing moves on its own during a meeting

- The user: "remember when in a zoom call we shutdown auto arrange". Keep Arranged stopped; three other automatic moves did not: a new browser placed beside its terminal, a learned habit suggested or applied, and a bound project's partners following (raised to the front, restored, moved to another display).
- During a meeting all three stop. Deskman still watches (focus, hand moves, learning records), so nothing is lost. What the person does, a snap hotkey or a drag to a zone, still works.
- Tests: `NothingMovesDuringAMeetingTests`, written before the code.
