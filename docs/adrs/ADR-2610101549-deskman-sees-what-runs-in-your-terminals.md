# ADR-2610101549: Deskman sees what runs in your terminals

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** The user: "we need to track what processes is running say in terminal". After the first window names (ADR-2610101542) came out as "◐ Claude Code" twice: the names need to know what each terminal is doing.

## Context

- Terminal windows are where the work is, and their titles say the least: Claude Code sets "✳ Claude Code" in every tab; a shell says "zsh". Warp and iTerm2 do not set `AXDocument`. The model cannot name what it is not told, so two terminals get the same name.
- Measured on the user's Mac, 2026-10-10, with no permission beyond what any process has:
  - Every terminal tab has a tty, and the tty's foreground process group gives the program in front: `claude` on ttys001 and ttys008, `ssh` on three tabs, `watcher`, and idle `zsh` shells.
  - Each process's working folder is readable: `claude` in `projects/beacon`, `claude` in `projects/deskman`.
  - Walking parent processes finds the terminal app: Warp (`Warp.app/…/stable`), iTerm2 (through its `iTermServer` daemon, which outlives the app).
- The gap: the process list knows the **app** a tab belongs to, never the **window**. macOS exposes no tty on a window. iTerm2 and Terminal answer "the tty of each window" over AppleScript, which needs the Automation permission. Warp has no AppleScript.
- Command-line arguments can hold secrets (tokens, passwords, hostnames). Deskman must never read or keep them.

## Decision

1. **A driven port, `TerminalActivity`**: returns the jobs running in terminals now. A job is: the terminal app, the tty, the program name (the executable's last path part, never its arguments), the working folder, and whether it is busy (anything other than a login shell sitting at its prompt).
2. **A new adapter, `adapters/secondary/processes`**, over libproc: `proc_listallpids`, `proc_pidinfo` with `PROC_PIDTBSDINFO` (parent, tty, foreground process group) and `PROC_PIDVNODEPATHINFO` (working folder). It reads; it signals and changes nothing. It knows terminal apps by bundle (Warp, iTerm2 and its `iTermServer`, Terminal, Ghostty, kitty, WezTerm, Alacritty).
3. **Jobs are matched to windows in the domain (`TerminalMatcher`)**, by evidence, strongest first:
   - The app has one window: every job belongs to it.
   - The window's title or document names the job's folder (last part) or program: that job belongs to it.
   - Otherwise a job belongs to the app, not to a window. It is still given to the namer as the app's context ("Warp runs: claude in beacon, watcher in beacon"), and never shown as belonging to one window.
4. **What jobs change:**
   - **Names** (ADR-2610101542): the namer gets each window's matched jobs ("claude in deskman"). A job change is a new key, so the window is named again.
   - **Activity** (ADR-2610101501): a terminal window with a busy job is never called idle, so Smart Arrange does not move it out of the way while something runs in it.
   - **The map and `listWindows`** show a terminal window's jobs under its name.
5. **Read every 15 seconds**, not every tick: jobs change slowly, and a scan of all processes is the cost.
6. **Not now:** per-window ttys over AppleScript for iTerm2 and Terminal. That needs the Automation permission and its own decision.

## Consequences

- Terminal windows get names that tell them apart ("Deskman Claude session", "Beacon Watcher") whenever a title, a document or a single window links a job to them.
- Two Warp windows with nothing in their titles still share their jobs at the app level. The names may still look alike there; the ADR says so rather than guessing a link.
- Deskman keeps program names and folders in memory only. It never reads arguments, never writes jobs to disk.

## Implementation

- Gate: `scripts/gate.sh`, with tests written before the code: `TerminalMatcherTests` (each rule in Decision 3, and that an ambiguous job is never given to a window), the idle rule, and the namer's input. A fake `TerminalActivity` in `Tests/DeskmanTests/Fakes.swift`.
- `--diagnose-terminals` prints the jobs the adapter finds and the window each one matched, so the person can check it against their own terminals.
- The gate's layer check gains the new adapter.

## References

- ADR-2610101542 (window names), ADR-2610101501 (activity, idle windows), ADR-2610101046 (the hexagon).

## Amendment 2026-10-10 — what the live check found

- **iTerm2 starts each shell through `/usr/bin/login`, which runs as root.** `proc_pidinfo` refuses another user's process, so the walk up to the terminal stopped there and every iTerm2 tab was missed. The adapter reads an ancestor's parent through `sysctl(KERN_PROC_PID)`, as `ps` does. Jobs themselves stay this user's processes only.
- **Claude Code's executable is named after its version** (`…/claude/versions/2.1.296`), so its process name is `2.1.296`. A version-like name gives way to the nearest folder in its path that is not `versions`, `bin` or a version. Arguments are still never read, so `argv[0]` stays out of reach on purpose.
- **Busy jobs speak for a window.** With four idle shells and two programs, the model named the window after a shell. The namer now hears only busy jobs when a window has any.
- Measured result on the user's Mac: Warp's window went from no name to "Claude in beacon". The two iTerm2 windows share the title "Claude Code", so their jobs stay with the app, and their names differ only by "2". That is Decision 3 working, not a fault; per-window ttys need the Automation permission (Decision 6).
