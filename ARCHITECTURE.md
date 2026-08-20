# Axoloty architecture

This document records the accepted architecture for the 0.6 alignment tracked by [epic #627](https://github.com/phynics/axoloty/issues/627). The repository is transitioning from the inherited Container/controller runtime; the current implementation and the accepted migration delta are intentionally separated below.

## Current implementation (0.5.1)

The released implementation still consists of the root `Axoloty` host product, the Foundation-free `AxolotyWire` product, the inspector/MCP tools, and the existing Embedded Swift integration. The host runtime still owns protocol coordination and object/lifecycle composition, while `AxolotyWire` supplies the extracted wire reader/writer and bounded embedded helpers. The inherited Container/controller and class-object paths remain current implementation details until G2–G5 replace them.

This section is the source of truth for what exists today. It must be updated whenever a gate changes the implemented package graph or removes a legacy path.

## Accepted 0.6 delta

The target package graph and runtime boundaries below are accepted direction, not claims about the 0.5.1 implementation. G2 owns the new protocol package and shared processor; G3 owns the object model; G4 owns runtime replacement; G5 owns IO and optional-product boundaries; G6 owns non-divergence and release proof.

## Product boundary

Axoloty is a core runtime plus first-party development tools.

The core consists of a portable wire implementation, portable protocol processing and state, a host runtime profile, and a static runtime profile. Inspector, MCP, and repository orchestration are first-party tools that consume supported runtime interfaces. SensorThings, Coaty convenience models, and automatic IO-routing policy are optional products rather than core protocol concerns.

## Runtime profiles

The host and static runtime profiles execute one portable protocol path. They may choose different capabilities, capacities, transports, ownership and delivery representations, scheduling adapters, and diagnostics. They may not differ in topic validation, event decoding, routing keys, correlation, duplicate or deadline behavior, association transitions, normalized actions, or canonical outbound wire behavior for overlapping inputs.

Inbound processing is:

```text
transport frame
  -> binding interpretation and topic validation
  -> event decoding and semantic validation
  -> routing-key derivation
  -> protocol-state transition
  -> normalized protocol actions
  -> runtime/application adapter
```

Outbound processing follows the same boundary in reverse, beginning with a typed local protocol operation and ending with a portable route/payload frame for a transport binding.

## Target dependency direction

```text
AxolotyWire
    ^
AxolotyProtocol
    ^
AxolotyStaticRuntime

Axoloty host runtime ----> AxolotyProtocol
Embedded firmware -------> AxolotyStaticRuntime
Optional products -------> supported Axoloty runtime and object APIs
Inspector / MCP ---------> supported Axoloty runtime APIs
```

`AxolotyWire` owns wire syntax, codecs, validation, object-envelope decoding, borrowed and owned wire values, caller-owned parser workspaces, and wire errors. It owns no subscribers, protocol state, transport, lifecycle, actors, or logging.

`AxolotyProtocol` owns the closed built-in profile inventory, capabilities, inbound and outbound processors, routing keys, finite correlation/deadline/association state, normalized actions, and protocol errors. It imports no MQTT/NIO, host object hierarchy, logging, actor, or controller framework.

`AxolotyStaticRuntime` owns fixed composition, static delivery, bounded presets, and portable endpoint integration. It contains no protocol rule absent from `AxolotyProtocol`.

## Architectural invariants

- `INV-001` **shared production processor (non-waivable):** host and static profiles compile the same production wire and protocol sources; no release may contain two production protocol processors.
- `INV-002` **sealed Coaty profile:** `coaty/3` is sealed as Coaty Core Profile 3; new first-party protocol primitives use separately versioned Axoloty profiles.
- `INV-003` **finite state:** portable protocol state is finite and saturation fails atomically with structured context.
- `INV-004` **borrowed-value scope:** borrowed values do not cross asynchronous or isolation boundaries.
- `INV-005` **typed external routes:** external non-Coaty routes exist only as typed Coaty IO external routes.
- `INV-006` **no general raw MQTT runtime API:** general raw MQTT application APIs are outside the target runtime.

Temporary violations require a narrow, expiring entry in [`docs/architecture-exceptions.yml`](./docs/architecture-exceptions.yml). The shared-production-processor invariant cannot be waived for a 0.6 release.

The ledger is JSON-compatible YAML with `schemaVersion: 1` and an `exceptions`
array. Each entry contains `id`, `invariant`, exact repository-relative `paths`,
`reason`, `ownerIssue`, `owner`, non-empty `compensatingTests`,
`introducedDate`, structured `expiry` (`kind` of `date` or `release` plus a
`value`), and `removalCondition`. The `repository validate` command rejects
unknown or duplicate invariants, broad paths, missing ownership/evidence,
expired entries, and attempts to waive `INV-001`.

## Documentation authority

When sources disagree, resolve the defect using this order:

1. executable code, manifests, and tests describe actual current behavior;
2. accepted ADRs record hard-to-reverse decisions and rationale;
3. GitHub issues and projects hold active plans and unresolved decisions;
4. [`docs/ROADMAP.md`](./docs/ROADMAP.md) summarizes active strategy;
5. README, API, support, migration, and release documents state public contracts;
6. AGENTS files define contributor policy.

Git history is the archive. Historical release notes remain immutable, accepted ADRs are superseded rather than rewritten, and obsolete plan prose is deleted once its durable rationale is captured.
