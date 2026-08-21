# Coaty Core Profile 3

This document is the normative Axoloty authority for the sealed `coaty/3`
compatibility profile. The portable package boundary now lands in [G2 issue
#638](https://github.com/phynics/axoloty/issues/638). Executable wire and
semantic behavior remains governed by production code, the compatibility
matrix, committed fixtures, and the pinned CoatyJS reference agent.

Every normative section carries an implementation-status label:

- **Complete** means current Axoloty code and compatibility evidence implement the section.
- **Inherited** means the pinned CoatyJS reference remains normative while Axoloty's current implementation and evidence are reconciled.
- **Later gate** means the requirement is accepted, but its portable implementation belongs to the named gate.

## Event families

**Status: Complete for the sealed inventory; Inherited for wire semantics.**

- Advertise / Deadvertise
- Channel
- Associate / IoValue
- Discover / Resolve
- Query / Retrieve
- Update / Complete
- Call / Return

`AxolotyProtocol` exposes the same 13-family closed inventory through
`ProtocolCapability`; `AxolotyWire` must understand every family even when a
runtime capability set exposes only a subset. Payload semantics remain
inherited from the pinned reference until #640.

## Compatibility rule

**Status: Complete.**

Axoloty matches the pinned CoatyJS reference where possible. A captured discrepancy is a defect unless matching is impossible or more harmful than an intentional break. Any unavoidable divergence requires regression coverage, evidence, and an update to [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md).

New Axoloty primitives must not add proprietary event codes to `coaty/3`; they belong to separately versioned Axoloty extension profiles.

## G2 trace contract

**Status: Complete for the package boundary, bounded state, and shared processing.**

The fixture-backed corpus and JSON contract in
[`Tests/ProtocolTrace/`](../../Tests/ProtocolTrace/) record deterministic prior
state, capabilities, finite limits, inputs, normalized actions, and structured
rejections for every Coaty Core family. The host and static replay adapters are
independent test implementations used to prove semantic equality. They invoke
the same production processor and compare normalized observations.
`AxolotyProtocol` owns fixed-inline state, caller-owned action sinks,
noncapturing handler tables, binding-supplied route classification, and shared
inbound/outbound processing. `AxolotyWire` owns no protocol state.

## Portable package boundary

**Status: Complete for #638, #639, #640, and #641.**

`Packages/AxolotyProtocol` is independently host-buildable and is compiled by
the ESP-IDF `axoloty_protocol` component from the same source glob. The target
depends only on `AxolotyWire`; Foundation, MQTT/NIO, logging, ErrorKit,
actors, controllers, lifecycle, and host object hierarchy are prohibited.
The package is intentionally a foundation rather than a runtime API: its
processor is a synchronous seam, not a transport or actor API.

## External IO routes

**Status: Complete for G2 semantics; later transport integration remains G5.**

External IO routes are transport-binding-specific exact non-Coaty routes associated through Coaty IO semantics. Canonical outbound Associate objects omit `isExternalRoute`. Inbound processing accepts the optional field only when it agrees with the binding-supplied classification; unrelated routes are ignored without inventing a global grammar.

## Evidence

**Status: Complete for current behavior; G2 and G6 extend the evidence for shared portable processing and non-divergence.**

- [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md)
- [`Tests/WireCompatibility/ReferenceAgents/`](../../Tests/WireCompatibility/ReferenceAgents/)
- [`Tests/WireCompatibility/Fixtures/`](../../Tests/WireCompatibility/Fixtures/)
