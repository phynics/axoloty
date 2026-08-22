# Coaty Core Profile 3

This document is the normative Axoloty authority for the sealed `coaty/3`
compatibility profile. The portable package boundary landed in [G2 issue
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
inherited from the pinned reference; the shared processor and trace replay
cover all 13 family transitions without promoting a runtime API.

## Compatibility rule

**Status: Complete.**

Axoloty matches the pinned CoatyJS reference where possible. A captured discrepancy is a defect unless matching is impossible or more harmful than an intentional break. Any unavoidable divergence requires regression coverage, evidence, and an update to [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md).

New Axoloty primitives must not add proprietary event codes to `coaty/3`; they belong to separately versioned Axoloty extension profiles.

## G2 trace contract

**Status: Complete for the package boundary, bounded state, and shared
processing; runtime integration remains a later gate.**

The fixture-backed corpus and JSON contract in
[`Tests/ProtocolTrace/`](../../Tests/ProtocolTrace/) record deterministic prior
state, capabilities, finite limits, inputs, normalized actions, and structured
rejections for every Coaty Core family. The host and static replay adapters are
test implementations over the same contract. Both invoke the shared
`ProtocolProcessor` inbound/outbound Interfaces with real borrowed frames and
typed local operations, then compare normalized observations.
`AxolotyProtocol` owns the fixed-inline processor seam, caller-owned action
sinks, generation-protected subscription/handler tables, binding-supplied
route classification, and shared inbound/outbound processing.
`AxolotyWire` owns no protocol state.

## Portable package boundary

**Status: Complete for #638, #639, #640, #641, and the G4 runtime integration
in #632.**

`Packages/AxolotyProtocol` is independently host-buildable and is compiled by
the ESP-IDF `axoloty_protocol` component from the same source glob. The target
depends only on `AxolotyWire` and `AxolotyObjectModel`; Foundation, MQTT/NIO, logging, ErrorKit,
actors, controllers, lifecycle, and host object hierarchy are prohibited.
The package remains a foundation rather than a transport API: its processor is
the single semantic engine used by both ``AxolotyRuntime`` and
``AxolotyStaticRuntime``. Actor scheduling, MQTT ownership, and stream delivery
remain in the host runtime; synchronous transport integration remains in the
static runtime.

## Object filters

**Status: Complete for the portable G3 path and the G4 runtime migration.**

Coaty `objectFilter` values decode into the bounded `ObjectPredicate` AST in
`AxolotyObjectModel`. That implementation owns all 15 Coaty operators,
canonical encode/decode, exact decimal comparison, Unicode-scalar string
ordering, LIKE matching, and local evaluation. `AxolotyProtocol` owns the
profile adapter and maps absent filters to match-all. The adapter does not
reinterpret `objectTypes` or `coreTypes` as predicates, and the new portable
path does not call the inherited host matcher. Predicate storage and failure
are bounded and atomic.

## External IO routes

**Status: Complete for G2 semantics and the G4 transport/runtime boundary;
typed IO endpoint ergonomics remain G5.**

External IO routes are transport-binding-specific exact non-Coaty routes associated through Coaty IO semantics. Canonical outbound Associate objects omit `isExternalRoute`. Inbound processing accepts the optional field only when it agrees with the binding-supplied classification; unrelated routes are ignored without inventing a global grammar.

## Evidence

**Status: Complete for current G2 evidence; G6 extends the evidence for
non-divergence and release proof.**

- [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md)
- [`Tests/WireCompatibility/ReferenceAgents/`](../../Tests/WireCompatibility/ReferenceAgents/)
- [`Tests/WireCompatibility/Fixtures/`](../../Tests/WireCompatibility/Fixtures/)
- [`Tests/ProtocolTrace/ProtocolTraceTests.swift`](../../Tests/ProtocolTrace/ProtocolTraceTests.swift)
- [`Packages/AxolotyProtocol/Tests/AxolotyProtocolTests/ProtocolProcessorTests.swift`](../../Packages/AxolotyProtocol/Tests/AxolotyProtocolTests/ProtocolProcessorTests.swift)
- [`Packages/AxolotyObjectModel/Tests/AxolotyObjectModelTests/ObjectPredicateTests.swift`](../../Packages/AxolotyObjectModel/Tests/AxolotyObjectModelTests/ObjectPredicateTests.swift)
- [`Spikes/BoundedObjectModelEvidence/EVIDENCE.md`](../../Spikes/BoundedObjectModelEvidence/EVIDENCE.md)
- [`Tests/Support/check-axoloty-wire-state-boundary.sh`](../../Tests/Support/check-axoloty-wire-state-boundary.sh)
