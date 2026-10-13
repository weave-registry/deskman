# ADR-2610101607: Switch to the right tab, and order tabs by activity

**Status:** Proposed — needs the user's choice on the Automation permission (Decision 1)
**Date:** 2026-10-10
**Drivers:** The user: "switch to proper tabs, arrange tabs based on activity" (ADR-2610101501 queue item 5).

## Context

- Deskman sees windows, not tabs. The Accessibility API does not list a browser's tabs in a form that can be switched or reordered, and macOS exposes no tab model across apps.
- Each app has its own way in, or none:
  - **Safari and Google Chrome** (and Chromium browsers that keep Chrome's dictionary: Brave, Edge, Arc in part) answer AppleScript: list a window's tabs with title and URL, make one active, close or move one. This needs the **Automation** permission, asked once per app by macOS.
  - **Firefox** has no AppleScript tab model. Reading its tabs means its session file (`sessionstore-backups/recovery.jsonlz4`, read-only, lags by seconds) or a browser extension.
  - **iTerm2** answers AppleScript and a Python API: sessions per tab, each with its tty. That also closes the gap in ADR-2610101549: which iTerm2 window runs which job.
  - **Warp** has no tab API.
- Tab titles and URLs are private: mail subjects, documents, search terms.

## Decision (proposed)

1. **Ask the user** whether Deskman may request the Automation permission for Safari, Chrome and iTerm2. Without it, this ADR is not built. With it:
2. **A driven port, `TabControl`**: list a window's tabs (title, URL host only, active or not), activate one, move one. One adapter per app family (`adapters/secondary/tabs-applescript` for Safari, Chrome and iTerm2), behind the port.
3. **"Switch to the right tab"**: `focus` a target that names a tab ("the pull request") finds the tab by title and activates it. Firefox and Warp say "Deskman cannot see this app's tabs".
4. **"Order tabs by activity"**: Deskman remembers when each tab was last active (in memory) and, on request only, moves the most active ones to the left. Never on its own: reordering under the person's hands is worse than disorder.
5. **iTerm2's ttys** replace the title evidence in `TerminalMatcher` for iTerm2: exact window for every job.
6. URLs are kept as their host only, in memory only, never written.

## Consequences

- Safari, Chrome and iTerm2 gain tab switching; Firefox and Warp do not, and Deskman says so.
- A permission prompt per app, which the user may refuse; each refusal is reported, not hidden.

## Implementation

- Not started. Gate when accepted: `scripts/gate.sh` with a fake `TabControl`, and `--diagnose-tabs` listing the tabs each adapter sees.
