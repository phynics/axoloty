# Axoloty roadmap

Axoloty is a Swift runtime and protocol suite for collaborative distributed agents across host systems and constrained devices. GitHub Issues are the complete planning record; this document is the curated active strategy.

## Current checkpoint

[`VERSION`](../VERSION) identifies the current released version (`0.5.1`). Axoloty remains pre-1.0 and its public API may change. The active development checkpoint is 0.6.

Historical release outcomes are preserved in [`docs/releases/`](./releases/) and [`CHANGELOG.md`](../CHANGELOG.md). They do not define current strategy.

## Active direction: 0.6 architecture alignment

[Epic #627](https://github.com/phynics/axoloty/issues/627) replaces the historical v1 direction in [#272](https://github.com/phynics/axoloty/issues/272). Axoloty 0.6 intentionally aligns host and constrained-device execution around one portable protocol critical path before any stability release.

The target outcomes are:

- one production wire, parser, schema, and protocol processor across host and static runtime profiles;
- explicit finite resource behavior and structured atomic saturation;
- a value-oriented typed and dynamic object model without a process-global class registry;
- structured `AxolotyRuntime` composition and lifecycle instead of Container/controller ownership;
- typed IO endpoints and binding-specific external IO routes without a general raw-MQTT runtime API;
- optional SensorThings, Coaty convenience-model, and automatic IO-routing products;
- structural, trace-equality, compatibility, resource, and documentation release gates.

The accepted boundaries and invariants are in [`ARCHITECTURE.md`](../ARCHITECTURE.md). Canonical terms are in [`CONTEXT.md`](../CONTEXT.md).

G2 is complete on `origin/main` via PR #646. G3 / #631 completes the portable
object model on this checkpoint; G4 / #632 is the next implementation gate and
will replace the inherited runtime/lifecycle path without redesigning the G3
model boundary.

## Sequential gates

| Gate | Outcome | Status |
|---|---|---|
| [G0 #628](https://github.com/phynics/axoloty/issues/628) | Establish direction and repository authority. | Complete |
| [G1 #629](https://github.com/phynics/axoloty/issues/629) | Prove bounded portable-toolchain assumptions. | Complete |
| [G2 #630](https://github.com/phynics/axoloty/issues/630) | Establish the portable wire/protocol foundation. | Complete |
| [G3 #631](https://github.com/phynics/axoloty/issues/631) | Ship the modern object model. | Complete |
| [G4 #632](https://github.com/phynics/axoloty/issues/632) | Replace the runtime and unify execution. | In progress |
| [G5 #633](https://github.com/phynics/axoloty/issues/633) | Modernize IO and optional product boundaries. | Blocked by G4 |
| [G6 #634](https://github.com/phynics/axoloty/issues/634) | Prove non-divergence and release 0.6. | Blocked by G5 |

Implementation tickets are created lazily as each gate opens. [AT Protocol research #522](https://github.com/phynics/axoloty/issues/522) may continue only as peripheral host-side exploration and must not reshape the portable 0.6 core.

## Explicit non-goals for 0.6

- a production `axoloty/1` extension profile;
- dynamic profile registration or live runtime reconfiguration;
- a schema migration engine;
- AT Protocol production integration;
- WASM, BLE, or libp2p transports;
- complete ESP32-C6 capability parity with the host profile;
- a second compatibility runtime or 1.0 API stability.
