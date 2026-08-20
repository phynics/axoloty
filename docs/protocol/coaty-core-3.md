# Coaty Core Profile 3

This document is the normative Axoloty authority for the sealed `coaty/3` compatibility profile. Until the portable protocol package lands in [G2](https://github.com/phynics/axoloty/issues/630), executable behavior remains governed by production code, the compatibility matrix, committed fixtures, and the pinned CoatyJS reference agent.

## Event families

- Advertise / Deadvertise
- Channel
- Associate / IoValue
- Discover / Resolve
- Query / Retrieve
- Update / Complete
- Call / Return

AxolotyWire must understand every family even when a runtime capability set exposes only a subset.

## Compatibility rule

Axoloty matches the pinned CoatyJS reference where possible. A captured discrepancy is a defect unless matching is impossible or more harmful than an intentional break. Any unavoidable divergence requires regression coverage, evidence, and an update to [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md).

New Axoloty primitives must not add proprietary event codes to `coaty/3`; they belong to separately versioned Axoloty extension profiles.

## External IO routes

External IO routes are transport-binding-specific exact non-Coaty routes associated through Coaty IO semantics. Canonical outbound Associate objects omit `isExternalRoute`. Inbound processing may accept the optional field only when it agrees with the route syntax inferred by the binding.

## Evidence

- [`Tests/WireCompatibility/CompatibilityMatrix.md`](../../Tests/WireCompatibility/CompatibilityMatrix.md)
- [`Tests/WireCompatibility/ReferenceAgents/`](../../Tests/WireCompatibility/ReferenceAgents/)
- [`Tests/WireCompatibility/Fixtures/`](../../Tests/WireCompatibility/Fixtures/)
