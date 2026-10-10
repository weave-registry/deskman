# ADR-2610101046: Deskman is a hexagonal Swift app, graded by its own target graph

**Status:** Accepted
**Date:** 2026-10-10
**Drivers:** A native macOS app that turns plain-language requests ("put Safari on the left") into window moves, with Apple's on-device model doing the interpretation, built to the hexa design practices.

## Context

- Apple's on-device model is reachable only through the `FoundationModels` Swift framework (macOS 26+). Rust, Go and TypeScript, the languages `hexa scaffold` and `hexa analyze` know, cannot call it without a Swift bridge.
- Window control on macOS goes through the Accessibility API (`AXUIElement`), which needs the user to grant the app Accessibility permission once.
- hexa's grade asks one question a test suite cannot: is the code the shape we asked for? `hexa analyze` does not parse Swift, so that question needs another judge here.
- The Accessibility API and AppKit use two different coordinate systems. AppKit puts the origin at the bottom-left of the primary display, y up. Accessibility puts it at the top-left, y down. Mixing them is the classic bug of this kind of app.

## Decision

1. **Swift, SwiftPM, macOS 26.** One package. One executable.
2. **One SwiftPM target per hexagonal layer.** The compiler is the grade:

   | Target | Layer | May depend on |
   |---|---|---|
   | `DeskmanDomain` | domain | nothing (Foundation only) |
   | `DeskmanPorts` | ports | `DeskmanDomain` (re-exported) |
   | `DeskmanUseCases` | usecases | `DeskmanPorts` |
   | `AccessibilityAdapter` | adapters/secondary | `DeskmanPorts` |
   | `FoundationModelsAdapter` | adapters/secondary | `DeskmanPorts` |
   | `DeskmanUI` | adapters/primary | `DeskmanPorts` |
   | `Deskman` | composition root | everything |

   `swift build --explicit-target-dependency-import-check error` turns an undeclared import into a build failure. An adapter cannot import another adapter, because no adapter declares one.
3. **Ports.**
   - `WindowControl` (driven): read windows and displays, set a frame, do an action, launch an app, report the Accessibility permission.
   - `Assistant` (driven): the language model. Turns text into a reply plus the actions it took.
   - `WindowCommands` (driving): what the assistant's tools may do. The use cases implement it.
   - `DeskmanPort` (driving): what the UI may do. The use cases implement it.
4. **Model independence (hexa G1).** Only `FoundationModelsAdapter` may import `FoundationModels` or name a model. Swapping in another model is a new adapter and one line in the composition root.
5. **One coordinate system inside the hexagon:** top-left origin, y down, in points, the Accessibility convention. Conversion from AppKit happens once, in `DeskmanDomain.CoordinateSpace`, and the Accessibility adapter calls it.
6. **Tools return outcomes, they do not throw.** A tool that throws ends the model's whole reply. A tool that returns "no window matches 'Foo'; open apps are …" lets the model try again.

## Consequences

- `hexa analyze .` cannot grade this project. `scripts/gate.sh` does the same job for Swift: the import check, a scan for forbidden imports per layer, and a test run that fails when zero tests ran.
- The on-device model has a small context window (about 4,096 tokens). Tool output stays short, tool count stays at five, and the conversation resets itself when the window fills.
- An ad-hoc signed build gets a new code identity on each rebuild, so macOS may ask for Accessibility permission again after a rebuild.

## Implementation

- Gate: `scripts/gate.sh` — written before the code, exits 0 only when every check passes and at least one test ran.
- Domain first (layouts, tiling, target matching, coordinates), then ports, use cases, adapters, composition root.
- `scripts/build-app.sh` wraps the binary in `Deskman.app` so macOS can grant it Accessibility permission.

## References

- hexa practices: https://git.local/gary/hexa (`CLAUDE.md`, `ARCHITECTURE.md`, `founding-goals.md` G1 and G3)
- ADR-2609121400 (hexa): the executable gate replaces the written spec.
