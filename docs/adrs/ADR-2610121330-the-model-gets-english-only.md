# ADR-2610121330: The model gets English only

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The map said "Naming paused: unsupportedLanguageOrLocale". The user: "fix the unsupported language error", "we should only use english".

## Context

- The Mac is `en_US`, which the on-device model supports. The error came from the prompt, not the settings.
- The system log: "Unsupported language detected", every 5 s from naming and from layout advice, 09:13 to 09:15, then gone. A window title held text in another language for two minutes.
- Reproduced: one foreign title among English ones is accepted. Titles that are most of the prompt (Hebrew, Russian, Polish) are refused, though the instructions are English. "Write in English" in the prompt saved Polish only.
- With the titles cut to ASCII, all three were accepted.

## Decision

1. **`EnglishOnly.text`** (domain): printable ASCII only. Other scripts, accents, emoji and invisible marks (WhatsApp's name starts with U+200E) go; spaces collapse.
2. Every window text Deskman puts in a prompt passes through it: app, title, name, project, folder and jobs, for naming, layout advice and the assistant's window list.
3. Should the model still refuse the language, naming and layout ask once more without titles. The app, folder and job still say what each window is.

## Consequences

- A title in another language adds nothing to a name; the window is named from its app, folder and job.
- What Deskman shows the person keeps the real titles. Only the prompts change.

## Implementation

- Gate: `scripts/gate.sh`, with `Tests/DeskmanTests/EnglishOnlyTests.swift` written before the code; live: `scripts/diagnose.sh names` and `layout`.

## Amendment 2026-10-12 — answers matched by number

- The map: "Naming paused: the model gave 2 names for 1 windows". The whole answer was thrown away, and the same window asked about again every few seconds.
- `NamedWindow.match` (domain) matches each answer by the window number it gives: extra answers and answers for windows not asked about are dropped; numbers from 0 are shifted; without usable numbers, the order counts when the count is right. The namer uses it; `WindowNames` still refuses an answer that leaves a window without one.
- Tests: `NamingMatchTests`, written before the code.
