# Axoloty roadmap

Axoloty is a modernized fork of [coatyio/coaty-swift](https://github.com/coatyio/coaty-swift)
for building distributed, collaborative IoT applications. This document is a
strategic summary; the live roadmap — with per-item status, phase, and
priority — is tracked on the
[Axoloty Roadmap](https://github.com/users/phynics/projects/5) GitHub Project,
and GitHub Issues are the complete planning record. For the agentic workflow
driving planning and execution, see [AGENTS.md](../AGENTS.md).

## Current release: 0.4 checkpoint

The current release is **Axoloty 0.4.0** — a development checkpoint tracked in
[#596 — Axoloty 0.4.0](https://github.com/phynics/axoloty/issues/596).

Axoloty 0.4 is **not** a v1 release and is **not** API-stable. It builds on the
host and embedded boundaries established in 0.2 and adds:

- Validated owned raw-JSON boundaries across `AxolotyWire`.
- Public Discover responder, decoded-object, join-state, and IO update-rate
  APIs.
- A productionized MQTT object inspector with distinct JSON and NDJSON output
  contracts and explicit private-data controls.
- Stable embedded identities, shared device leases, and stage-rich release
  evidence.
- A canonical test driver, warning-free builds, and reusable development
  container images.

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
| 2 | [#275](https://github.com/phynics/axoloty/issues/275) | Extract `AxolotyWire`, a Foundation-free wire module with an allowlisted standalone package closure. | ✅ Closed |
| 3 | [#276](https://github.com/phynics/axoloty/issues/276) | Establish resource and performance budgets. | ✅ Closed |
| 4 | [#277](https://github.com/phynics/axoloty/issues/277) | Prove the ESP32-C6 vertical slice: Advertise/Deadvertise and Discover/Resolve. | ✅ Closed |
| 0.2 | [#278](https://github.com/phynics/axoloty/issues/278) | Stabilize, document, and release the 0.2 checkpoint. | ✅ Closed |
| 0.4 | [#596](https://github.com/phynics/axoloty/issues/596) | Harden wire boundaries, inspector behavior, embedded evidence, and repository tooling. | ✅ Released |
| Inspector | [#344](https://github.com/phynics/axoloty/issues/344) | MQTT object inspector CLI (`axoloty-inspect`) for passive catalogue and active discovery. | ✅ Closed |

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

- `AxolotyWire` has no host runtime dependencies; its standalone package has
  one direct `swift-json` / `IkigaJSONCore` parser dependency and an
  allowlisted transitive resolution closure validated by the distribution
  gate.
- `AxolotyWire` imports no Foundation, NIO, MQTT, ErrorKit, or logging modules
  and uses no actors.
- Borrowed values never cross asynchronous seams.
- No mutable transport or router state relies on `@unchecked Sendable`.
- Existing CoatyJS fixture, live-wire, IO, lifecycle, and SensorThings
  compatibility gates remain green. The live wire gate is enforced in CI for
  protocol-affecting changes (#457) with recorded evidence and an explicit,
  expiring reviewed exemption.
- Advertise/Deadvertise and Discover/Resolve run on the selected ESP32-C6
  within recorded RAM, stack, flash, payload-size, and sustained-rate budgets.
