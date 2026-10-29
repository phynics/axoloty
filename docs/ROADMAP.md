# Axoloty roadmap

Axoloty is a bounded, Embedded-Swift-capable distributed object runtime with
Coaty wire semantics. `coaty/3` JSON preserves Coaty compatibility, and
`axoloty/1` CBOR is the native profile. GitHub Issues are the complete planning
record; this document summarizes the active strategy.

## Current checkpoint

[`VERSION`](../VERSION) identifies the current released version (`0.10.0`). Axoloty remains pre-1.0 and its public API may change. The 0.10 line is the active checkpoint.

Historical release outcomes are preserved in [`docs/releases/`](./releases/) and [`CHANGELOG.md`](../CHANGELOG.md). They do not define current strategy.

## Active direction: complete the Core 1.0 contract

Axoloty 0.10.0 ships the `axoloty/1` CBOR profile
([epic #977](https://github.com/phynics/axoloty/issues/977)), makes it the only
Zenoh encoding, and freezes the candidate Core 1.0 surface. Firmware locks to
the `v0.10.0` tag. Axoloty 0.9.0 closed
[epic #845](https://github.com/phynics/axoloty/issues/845), which moved
firmware and device qualification into `phynics/axoloty-embedded`, and shipped
the host Zenoh transport from
[epic #796](https://github.com/phynics/axoloty/issues/796) as experimental.
The release records are [`docs/releases/0.10.0.md`](./releases/0.10.0.md) and
[`docs/releases/0.9.0.md`](./releases/0.9.0.md). The approved product and
ownership contracts are in
[ADR 0012](./adr/0012-approved-product-and-ownership-contracts.md).

### Zenoh status

- **Host binding:** shipped experimental in 0.9.0 as the `AxolotyZenoh`
  package, in client and peer modes.
- **Embedded binding:** firmware and carrier work belong to
  `phynics/axoloty-embedded`. Device peer-mode qualification is deferred beyond
  embedded v1.
- **Wire encoding is `axoloty/1` CBOR.** The profile shipped in 0.10.0, and
  [ADR 0009](./adr/0009-zenoh-carries-only-axoloty-1.md) makes Zenoh carry only
  that profile. Zenoh peers built on 0.9.x do not interoperate with 0.10.0 or
  later.
- **Consumption:** the adapter is consumed by path from a checkout, not through
  a URL dependency ([ADR 0007](./adr/0007-zenoh-adapter-package-boundary.md)).
  Zenoh remains outside the Core 1.0 stability contract. Promotion is tracked
  separately in [#1045](https://github.com/phynics/axoloty/issues/1045).

### 1.0 scope

The 1.0 API freeze covers the following:

- **Stable Core 1.0 products:** `Axoloty`, `AxolotyWire`, `AxolotyProtocol`,
  `AxolotyObjectModel`, `AxolotyStaticRuntime`, and `AxolotyMQTT`.
- **Everything else is experimental** for Core 1.0. This includes Zenoh,
  Coaty convenience models, SensorThings and IO-routing products,
  macro-generated schema support, the `Tools/` harness, and products in the
  sibling `phynics/axoloty-debug` package.
- **`axoloty/1` CBOR is in 1.0 scope and implemented on `main`.** The bounded
  codec, `axoloty/1` routes, frozen golden corpus, host/static trace parity,
  Zenoh-only profile, and embedded consumer contract surface are in the tree.
  [ADR 0009](./adr/0009-zenoh-carries-only-axoloty-1.md) makes it the only
  Zenoh encoding, and `coaty/3` JSON stays sealed on MQTT for CoatyJS
  compatibility. [Epic #977](https://github.com/phynics/axoloty/issues/977)
  delivered the profile and closed. Remaining 1.0 acceptance work is tracked in
  [#1043](https://github.com/phynics/axoloty/issues/1043). The `wire-cbor` tier
  runs the corpus and trace parity on every pull request.
- **Not frozen:** a JSON Zenoh encoding, or any JSON-only codec surface that the
  CBOR profile would replace.

The version numbers, deprecation window, and security support for these
products are recorded in [the versioning and deprecation policy](./versioning.md)
and [`SECURITY.md`](../SECURITY.md). Scoping decisions are recorded in the
closed historical review
[#978](https://github.com/phynics/axoloty/issues/978). Remaining 1.0 acceptance
work is tracked in
[#1043](https://github.com/phynics/axoloty/issues/1043), and the API audit is
tracked in [#1000](https://github.com/phynics/axoloty/issues/1000).

## Completed: 0.7 architecture stabilization and transport boundary

The 0.7 line had two accepted programs. [Epic #753](https://github.com/phynics/axoloty/issues/753)
concentrated
orchestration, runtime registration, SensorThings workflows, and typed IO
state behind deep modules with explicit ownership.

The delivered outcomes are:

- runtime composition is explicit: `RuntimeBuilder` owns a finite
  transactional registration draft and `RuntimeDefinition` is the immutable
  value produced by `finish()`;
- first-party runtime modules use stable keys, and duplicate registration is
  rejected atomically;
- SensorThings supports Thing-driven observation through a bounded registry;
- typed IO state is concentrated behind the executor that owns it;
- canonical test tiers declare their execution boundaries; live Zenoh is an
  opt-in router-backed tier, separate from ordinary verification; attested
  tier nodes run only when their owning tier is selected.

[Epic #781](https://github.com/phynics/axoloty/issues/781) then made the
transport a declared, enforced boundary: MQTT behind an adapter product, a
transport port that carries a finished route, a package-scoped runtime
extension surface, a machine-checked module policy, and a root package that
declares only libraries. It carries the v0.7.0 release, because its changes are
source-breaking and landed before 0.7.0 was tagged; releasing twice would ask
consumers to migrate twice for one architectural change.

Outcomes are recorded in [`docs/releases/0.7.0.md`](./releases/0.7.0.md) and
the removed public API is mapped in
[the migration guide](./migration/from-0.6-to-0.7.md).

### 0.7 delivery

| Issue | Outcome | Status |
|---|---|---|
| [#755](https://github.com/phynics/axoloty/issues/755) | Centralize canonical test-plan resolution. | Merged |
| [#754](https://github.com/phynics/axoloty/issues/754) | Extract release certification commands. | Merged |
| [#756](https://github.com/phynics/axoloty/issues/756) | Split remaining tooling command families. | Merged |
| [#758](https://github.com/phynics/axoloty/issues/758) | Replace runtime construction and registration. | Merged |
| [#759](https://github.com/phynics/axoloty/issues/759) | Install SensorThings sources and direct observation. | Merged |
| [#757](https://github.com/phynics/axoloty/issues/757) | Add Thing-driven bounded SensorThings registry. | Merged |
| [#760](https://github.com/phynics/axoloty/issues/760) | Concentrate executor-owned typed IO state. | Merged |

The `embedded` category is the hardware-free Core Embedded Swift gate and runs
on the pinned Linux container. Device qualification is recorded in
`phynics/axoloty-embedded`.

## Completed: 0.6 architecture alignment

[Epic #627](https://github.com/phynics/axoloty/issues/627) replaced the historical v1 direction in [#272](https://github.com/phynics/axoloty/issues/272). Axoloty 0.6 aligned host and constrained-device execution around one portable protocol critical path before any stability release.

The delivered outcomes were:

- one production wire, parser, schema, and protocol processor across host and static runtime profiles;
- explicit finite resource behavior and structured atomic saturation;
- a value-oriented typed and dynamic object model without a process-global class registry;
- structured `AxolotyRuntime` composition and lifecycle instead of Container/controller ownership;
- typed IO endpoints and binding-specific external IO routes without a general raw-MQTT runtime API;
- optional SensorThings, Coaty convenience-model, and automatic IO-routing products;
- structural, trace-equality, compatibility, resource, and documentation release gates.

The accepted boundaries and invariants are in [`ARCHITECTURE.md`](../ARCHITECTURE.md). Canonical terms are in [`CONTEXT.md`](../CONTEXT.md).

G0 through G6 are complete. G5 / #633 delivered typed IO, binding-specific
external routes, and the optional `AxolotyIoRouting` and `AxolotySensorThings`
products. G6 / #634 delivered the 0.6 release gate.

### 0.6 gates

| Gate | Outcome | Status |
|---|---|---|
| [G0 #628](https://github.com/phynics/axoloty/issues/628) | Establish direction and repository authority. | Complete |
| [G1 #629](https://github.com/phynics/axoloty/issues/629) | Prove bounded portable-toolchain assumptions. | Complete |
| [G2 #630](https://github.com/phynics/axoloty/issues/630) | Establish the portable wire/protocol foundation. | Complete |
| [G3 #631](https://github.com/phynics/axoloty/issues/631) | Ship the modern object model. | Complete |
| [G4 #632](https://github.com/phynics/axoloty/issues/632) | Replace the runtime and unify execution. | Complete |
| [G5 #633](https://github.com/phynics/axoloty/issues/633) | Modernize IO and optional product boundaries. | Complete |
| [G6 #634](https://github.com/phynics/axoloty/issues/634) | Prove non-divergence and release 0.6. | Complete |

Implementation tickets are created lazily as each gate opens. [AT Protocol research #522](https://github.com/phynics/axoloty/issues/522) may continue only as peripheral host-side exploration and must not reshape the portable 0.6 core.

## Explicit non-goals

The Core 1.0 contract excludes the following:

- a replicated object store;
- Core consensus or Raft;
- automatic replay of accepted request commands after reconnect;
- controller restoration;
- a Core authentication or authorization contract;
- an automatic bridge between wire domains or transports;
- BLE Mesh or other BLE transports;
- device peer-mode qualification before embedded v1;
- dynamic profile registration or live runtime reconfiguration;
- a schema migration engine;
- AT Protocol production integration;
- WASM or libp2p transports;
- complete ESP32-C6 capability parity with the host profile;
- a second compatibility runtime.

The full ownership and supersession map is in
[ADR 0012](./adr/0012-approved-product-and-ownership-contracts.md).
