# Axoloty v1.0 Roadmap

Axoloty v1.0 — lean, safe, embedded-ready. This document is a strategic
summary; the live roadmap — with per-item status, phase, and priority — is
tracked on the
[Axoloty Roadmap](https://github.com/users/phynics/projects/5) GitHub Project,
and GitHub Issues are the complete planning record. For the agentic workflow
driving planning and execution, see [AGENTS.md](../AGENTS.md).

The v1 tracker is
[#272 — Axoloty v1.0 — lean, safe, embedded-ready](https://github.com/phynics/axoloty/issues/272).

## North star

Axoloty provides a small, bounded-resource, Coaty-compatible edge core with a
safe host runtime layered on top. Host conveniences impose no dependency,
allocation, or platform cost on embedded builds.

## v1 outcome

Version 1.0 ships a stable host library and a separately consumable
Foundation-free wire module, with an ESP32-C6 proof completing
Advertise/Deadvertise and Discover/Resolve against Axoloty and pinned CoatyJS
within explicit resource budgets.

## Design choices

- Share a deep wire module, not the complete host runtime.
- Preserve the Coaty JSON contract and the existing compatibility suite.
- Keep borrowed bytes synchronous and scoped; materialize owned bytes before
  any async hop.
- Keep embedded routing bounded and single-threaded; host synchronization
  belongs in a host adapter.
- Use static embedded composition and retain dynamic registration only in the
  host runtime.
- Keep the current WireReader/WireWriter unless measurements prove replacement
  is necessary.
- Create implementation tickets for a phase only when the preceding gate
  passes.

## Non-goals

- Porting Foundation, NIO, ErrorKit, swift-log, the host IoC container, or
  every controller to Embedded Swift.
- A parallel WASM roadmap without a concrete consumer.
- A SwiftData/SwiftUI facade before the v1 core is stable.
- Zero-copy borrowed buffers crossing actors, tasks, or suspension points.
- Expanding the first embedded release beyond Advertise/Deadvertise and
  Discover/Resolve.

## Phases

Gates are sequential: a later phase stays in Backlog until the preceding gate
closes. Each gate's tracking issue carries the full scope, non-goals, gate
criteria, and validation commands.

| Phase | Gate | Outcome |
|---|---|---|
| 0 | [#273](https://github.com/phynics/axoloty/issues/273) | Finish and clear the inherited backlog; leave no pre-roadmap ambiguity. |
| 1 | [#274](https://github.com/phynics/axoloty/issues/274) | Establish the host safety boundary: atomic bootstrap, owned bytes before async delivery, no falsely `Sendable` mutable transport/router state. |
| 2 | [#275](https://github.com/phynics/axoloty/issues/275) | Extract `AxolotyWire`, a dependency-free Foundation-free wire module the host consumes without changing wire behavior. |
| 3 | [#276](https://github.com/phynics/axoloty/issues/276) | Establish resource and performance budgets: latency, allocations, binary size, malformed-input bounds, and ESP32-C6 RAM/stack/flash/rate budgets. |
| 4 | [#277](https://github.com/phynics/axoloty/issues/277) | Prove the ESP32-C6 vertical slice: Advertise/Deadvertise and Discover/Resolve against Axoloty and pinned CoatyJS within budget. |
| 5 | [#278](https://github.com/phynics/axoloty/issues/278) | Lean the host, document the v1 interface and support matrix, and tag v1.0.0. |

## Cross-cutting success metrics

- `AxolotyWire` has zero external runtime dependencies.
- `AxolotyWire` imports no Foundation, NIO, MQTT, ErrorKit, or logging modules
  and uses no actors.
- Borrowed values never cross asynchronous seams.
- No mutable transport or router state relies on `@unchecked Sendable`.
- Existing CoatyJS fixture, live-wire, IO, lifecycle, and SensorThings
  compatibility gates remain green.
- Advertise/Deadvertise and Discover/Resolve run on the selected ESP32-C6
  within recorded RAM, stack, flash, payload-size, and sustained-rate budgets.
- The roadmap contains one active deployment direction and no competing
  speculative epics.

## Release criteria

- Every phase gate closes in order.
- Canonical build, test, lint, documentation, and wire-compatibility commands
  pass.
- Public interfaces and migration notes are documented for v1.
- Supported host and embedded capabilities are stated explicitly.
- A release candidate is validated from a clean checkout before tagging
  v1.0.0.
