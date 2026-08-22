# Axoloty architecture

This document records the accepted architecture for the 0.6 alignment tracked by [epic #627](https://github.com/phynics/axoloty/issues/627). The repository has completed the G4 runtime cutover in PR [#649](https://github.com/phynics/axoloty/pull/649); the published version remains `0.5.1` until the 0.6 gates finish.

## Current implementation (0.6 G4 checkpoint)

The released implementation now consists of the root `Axoloty` host product,
the Foundation-free `AxolotyWire`, `AxolotyObjectModel`, and
`AxolotyProtocol` products, the separate `AxolotyCoatyModels` convenience
product, the inspector/MCP tools, and the existing Embedded Swift integration.
The host runtime contains the G4 ``AxolotyRuntime`` lifecycle and
``MQTTBinding``. The inherited class-object, controller, manager, and
SensorThings runtime hierarchy has been removed from active production
targets; G5 will reintroduce only modern optional products. `AxolotyWire` supplies
profile-neutral wire syntax, borrowed values, and caller-owned parser
workspaces; `AxolotyObjectModel` supplies bounded semantic objects, schemas,
predicates, and runtime-local registration; `AxolotyProtocol` supplies the
sealed Coaty/3 inventory, routing-key/frame types, structured protocol errors,
fixed-inline state, caller-owned action sinks, route classification, the
shared inbound/outbound processor, and Coaty filter adaptation. Inspector and MCP
consume the runtime through owned event/request values and
do not expose transport topics. Embedded firmware composes
``AxolotyStaticRuntime`` and owns only transport, platform, and main-loop
concerns.

This section is the source of truth for what exists today. It must be updated whenever a gate changes the implemented package graph or removes a legacy path.

### G2 status: shared fixed-inline processor

Issue [#638](https://github.com/phynics/axoloty/issues/638) now lands the
standalone [`Packages/AxolotyProtocol`](./Packages/AxolotyProtocol) package
and the matching root product. Its host and ESP-IDF source-inclusion checks
compile the same Foundation-free sources. Issue
[#640](https://github.com/phynics/axoloty/issues/640) now owns the
fixed-inline processor seam, bounded action sink, handler table, and
binding-supplied route classifier. The state-owning sources are under
`AxolotyProtocol`; `AxolotyWire` contains only syntax, codecs, validation,
values, errors, and parser workspaces. Trace adapters translate fixtures into
real borrowed frames and typed local operations before calling the shared
`ProtocolProcessor` Interfaces. The processor
also owns the fixed-inline subscription registry and generation-protected
handler table; no router or endpoint compatibility state remains in
`AxolotyWire`.

The fixture-backed trace contract and host/static replay adapters under
`Tests/ProtocolTrace` remain test-only. Both use the same production processor
and fixed action sink seam, without promoting a second processor. Issue
[#637](https://github.com/phynics/axoloty/issues/637) records that contract;
[#639](https://github.com/phynics/axoloty/issues/639) is closed by the state
move; [#641](https://github.com/phynics/axoloty/issues/641) is closed by the
binding-supplied route classifier.

### G3 status: portable object model complete

Issue [#631](https://github.com/phynics/axoloty/issues/631) establishes the
production `AxolotyObjectModel`, build-time `AxolotyObjectMacros`, and
first-party `AxolotyCoatyModels` packages. Host and ESP-IDF consumers compile
the same object-model and first-party-model sources. The portable model owns
bounded raw JSON, inline descriptors, semantic envelopes, checked number
views, presence, typed/manual schemas, transactional edits, fixed runtime-local
registration, and the bounded Coaty-compatible predicate AST. Macro-generated
schemas and manual conformances implement the same `ObjectSchema` contract;
the macro is not an Embedded runtime dependency.

`AxolotyProtocol` adapts Coaty `objectFilter` values into the shared predicate
implementation. Unknown object types remain dynamic, registration has no
process-global side effects, and unknown fields and number lexemes remain in
the same bounded object arena. `AxolotyCoatyModels` supplies the portable
protocol-required Coaty/IO schemas as a separate convenience product. The
inherited Foundation-backed hierarchy was removed by G4; excluded legacy
fixtures remain historical evidence only. G3 does not introduce a second
runtime or lifecycle.
The boundary checks and the maintained
[`Spikes/BoundedObjectModelEvidence`](./Spikes/BoundedObjectModelEvidence)
host/sanitizer/ESP32-C6 evidence enforce this package graph and its
fixed-storage claims.

### G4 status: runtime replacement complete

The ``Axoloty`` target has an explicit modern source list containing the
runtime definition, host runtime, MQTT binding, transport client, and error
boundary. Its private actor executor owns bounded ingress, dispatch, lifecycle,
reconnect, cancellation, and diagnostics while all thirteen protocol families
enter the shared ``ProtocolProcessor``. ``AxolotyStaticRuntime`` provides the
fixed synchronous profile for Embedded Swift. Inspector and MCP use the same
runtime contracts, and neutral benchmark consumers measure protocol,
object-model, host-runtime, and static-runtime products.

The strict G4 package and consumer boundaries are required gates. They reject
legacy runtime symbols, raw MQTT APIs outside the binding, parallel encoders,
and implicit SwiftPM source discovery. Controller-based IO and SensorThings
remain intentionally absent until G5.

## Accepted 0.6 delta

The target package graph and runtime boundaries below are accepted direction,
with the shared `AxolotyProtocol` processor implemented in G2 and the portable
object-model slice implemented in G3.
G1 accepted [ADR 0004](./docs/adr/0004-literal-inline-bounded-runtime-state.md)
from host and ESP32-C6 evidence, selecting measured tiny/static/host capacity
presets of 1/16/64 for runtime state. Those measurements do not select G3
object byte/field capacities: G3 owns the object model and its own evidence;
host evidence covers bounded operations and specialization growth at the
1/16/64 measurement points, while the 512-byte/24-field convenience aliases
remain wire-authority bounds rather than resource presets. The ESP32-C6 node
proves same-source compilation and linkage. G4 owns runtime replacement;
G5 owns IO and optional-product boundaries; G6 owns non-divergence and release
proof.

The canonical `g4-runtime` tier contains lifecycle, static, host, concurrency,
boundary, and package checks. The tier and its boundary nodes are required:
replacement sources must not retain inherited lifecycle or parallel encoder
symbols, and every current inspector/MCP consumer must use the replacement
runtime or be removed. The reports are acceptance evidence, not an allowlist
or an architecture exception.

## Product boundary

Axoloty is a core runtime plus first-party development tools.

The core consists of a portable wire implementation, portable protocol processing and state, a host runtime profile, and a static runtime profile. Inspector, MCP, and repository orchestration are first-party tools that consume supported runtime interfaces. SensorThings, Coaty convenience models, and automatic IO-routing policy are optional products rather than core protocol concerns.

## Runtime profiles

The host and static runtime profiles execute one portable protocol path. They
may choose different capabilities, capacities, transports, ownership and
delivery representations, scheduling adapters, and diagnostics, but they may
not differ in protocol semantics for overlapping inputs. The test adapters
provide replay evidence for this shared path; G4 now supplies the host actor
and lifecycle runtime that owns transport scheduling and application delivery.

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
AxolotyObjectModel
    ^
AxolotyProtocol
    ^
AxolotyStaticRuntime

Axoloty host runtime ----> AxolotyProtocol
Embedded firmware -------> AxolotyStaticRuntime
Optional products -------> supported Axoloty runtime and object APIs
Inspector / MCP ---------> supported Axoloty runtime APIs
```

`AxolotyWire` owns wire syntax, codecs, validation, low-level object-envelope
decoding, borrowed and owned wire values, caller-owned parser workspaces, and
wire errors. It owns no semantic object schema, subscriber, endpoint,
association, correlation, handler, or processor state.

`AxolotyObjectModel` is the implemented G3 semantic layer above `AxolotyWire`.
It owns bounded typed/dynamic objects, presence, semantic envelopes, JSON
value/number views, predicates, and explicit sealed schema registries. It does
not own a transport, protocol processor, runtime
lifecycle, or global mutable registry. `AxolotyObjectMacros` is a build-time
schema-generation package and is not part of the portable runtime graph.

`AxolotyCoatyModels` is a separate first-party convenience product containing
portable protocol-required Coaty and IO schemas. It depends on
`AxolotyObjectModel` and is compiled from the same sources for host and
ESP-IDF. The G4 host runtime does not expose typed IO; G5 owns that optional
product boundary.

`AxolotyProtocol` owns the closed built-in profile inventory, capabilities,
routing keys, portable frames, structured protocol errors, fixed-inline
request/association/subscriber state and subscription registry, protocol
capacities, route classifiers, handler tables, action sinks, and the shared
inbound/outbound processor. It
does not own a transport. It imports no MQTT/NIO, host object hierarchy,
logging, actor, or controller framework.

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
