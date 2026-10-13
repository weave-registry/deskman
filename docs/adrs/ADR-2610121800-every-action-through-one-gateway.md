# ADR-2610121800: Every window action goes through one gateway

**Status:** Accepted
**Date:** 2026-10-12
**Drivers:** The user: "build the gateway", after CopilotKit OpenBot's: "every action decided before it happens and recorded after".

## Context

- Deskman's rules lived in each service: the meeting freeze in Keep Arranged, the tick and bound projects; never-minimize in Smart Arrange; the active window in Keep Arranged. Each new path had to repeat them, and several leaked before they were added.
- The decision log recorded what Smart Arrange planned, not every action every path took.

## Decision

1. **`GatewayPolicy`** (domain): one table of rules. What the person asks for is done. On its own, Deskman never minimizes, closes, hides or fills the screen; moves nothing during a meeting; never moves the window being worked in; never touches a meeting app; leaves alone a window it cannot see.
2. **`ActionOrigin`**: every action says who asked — the person (Smart Arrange click, a snap hotkey or drag, Undo, an accepted suggestion, the assistant) or Deskman on its own (Keep Arranged, a learned habit, a bound project, a new browser placed). No origin means Deskman on its own: the strict rules.
3. **`WindowGateway`** (use cases) wraps the window control once, outermost, in the composition root. Every move, resize, minimize, restore, focus and close is decided by the policy, refused with a `GatewayRefusal` that says why, and recorded in the decision log: "Did …", "Refused …", "Failed …", with who asked.
4. The rules in the services stay: they avoid planning what the gateway would refuse. The gateway is the guarantee.

## Consequences

- A new path that moves windows cannot break the rules by forgetting them; it can only state its origin.
- The decision log has one line per action, from one place.

## Implementation

- Gate: `scripts/gate.sh`, with `GatewayPolicyTests` and `WindowGatewayTests` written before the code.
