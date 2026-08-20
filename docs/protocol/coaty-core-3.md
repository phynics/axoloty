# Coaty Core Profile 3

This document is the normative Axoloty authority for the sealed `coaty/3` compatibility profile. Until the portable protocol package lands in [G2](https://github.com/phynics/axoloty/issues/630), executable behavior remains governed by production code, the compatibility matrix, committed fixtures, and the pinned CoatyJS reference agent.

Every normative section carries an implementation-status label:

- **Complete** means current Axoloty code and compatibility evidence implement the section.
- **Inherited** means the pinned CoatyJS reference remains normative while Axoloty's current implementation and evidence are reconciled.
- **Later gate** means the requirement is accepted, but its portable implementation belongs to the named gate.

## Event families

**Status: Inherited (G2 owns portable implementation).**

- Advertise / Deadvertise
- Channel
- Associate / IoValue
- Discover / Resolve
- Query / Retrieve
- Update / Complete
- Call / Return

AxolotyWire must understand every family even when a runtime capability set exposes only a subset.

## Compatibility rule

**Status: Complete.**

Axoloty matches the pinned CoatyJS reference where possible. A captured discrepancy is a defect unless matching is impossible or more harmful than an intentional break. Any unavoidable divergence requires regression coverage, evidence, and an update to [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md).

New Axoloty primitives must not add proprietary event codes to `coaty/3`; they belong to separately versioned Axoloty extension profiles.

## External IO routes

**Status: Later gate (G5).** Current decoding behavior is retained during migration; G5 owns the typed portable boundary and final evidence.

External IO routes are transport-binding-specific exact non-Coaty routes associated through Coaty IO semantics. Canonical outbound Associate objects omit `isExternalRoute`. Inbound processing may accept the optional field only when it agrees with the route syntax inferred by the binding.

## Evidence

**Status: Complete for current behavior; G2 and G6 extend the evidence for shared portable processing and non-divergence.**

- [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md)
- [`Tests/WireCompatibility/ReferenceAgents/`](../../Tests/WireCompatibility/ReferenceAgents/)
- [`Tests/WireCompatibility/Fixtures/`](../../Tests/WireCompatibility/Fixtures/)
