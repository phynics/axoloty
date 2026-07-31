# Axoloty roadmap

Axoloty is a modernized fork of [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift)
for building distributed, collaborative IoT applications. This document is a
strategic summary; the live roadmap — with per-item status, phase, and
priority — is tracked on the
[Axoloty Roadmap](https://github.com/users/phynics/projects/5) GitHub Project,
and GitHub Issues are the complete planning record. For the agentic workflow
driving planning and execution, see [AGENTS.md](../AGENTS.md).

## Current release: 0.2 checkpoint

The immediate release is **Axoloty 0.2.0** — a development checkpoint that
records architectural progress made so far. It is tracked in
[#278 — 0.2 checkpoint](https://github.com/phynics/axoloty/issues/278).

Axoloty 0.2 is **not** a v1 release and is **not** API-stable. It provides:

- Safe host runtime boundaries.
- Dependency-free `AxolotyWire` module.
- Embedded Swift support on ESP32-C6 (Advertise/Deadvertise, Discover/Resolve).
- Current host and device performance evidence.
- Typed Swift repository tooling.
- Accurate documentation of what works and what remains experimental.

## Future direction: v1.0

The original v1.0 direction is preserved as future work in
[#272 — Axoloty v1.0 — lean, safe, embedded-ready](https://github.com/phynics/axoloty/issues/272).
The v1 north star remains:

> Axoloty provides a small, bounded-resource, Coaty-compatible edge core
> with a safe host runtime layered on top. Host conveniences impose no
> dependency, allocation, or platform cost on embedded builds.

## Completed phases

| Phase | Gate | Outcome | Status |
|---|---|---|---|
| 0 | [#273](https://github.com/phynics/axoloty/issues/273) | Finish and clear the inherited backlog. | ✅ Closed |
| 1 | [#274](https://github.com/phynics/axoloty/issues/274) | Establish the host safety boundary. | ✅ Closed |
| 2 | [#275](https://github.com/phynics/axoloty/issues/275) | Extract `AxolotyWire`, a dependency-free Foundation-free wire module. | ✅ Closed |
| 3 | [#276](https://github.com/phynics/axoloty/issues/276) | Establish resource and performance budgets. | ✅ Closed |
| 4 | [#277](https://github.com/phynics/axoloty/issues/277) | Prove the ESP32-C6 vertical slice: Advertise/Deadvertise and Discover/Resolve. | ✅ Closed |
| 0.2 | [#278](https://github.com/phynics/axoloty/issues/278) | Stabilize, document, and release the 0.2 checkpoint. | 🔄 In progress |

## Design choices

- Share a deep wire module, not the complete host runtime.
- Preserve the Coaty JSON contract and the existing compatibility suite.
- Keep borrowed bytes synchronous and scoped; materialize owned bytes before
  any async hop.
- Keep embedded routing bounded and single-threaded; host synchronization
  belongs in a host adapter.
- Use static embedded composition and retain dynamic registration only in
  the host runtime.
- Keep the current WireReader/WireWriter unless measurements prove replacement
  is necessary.

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
