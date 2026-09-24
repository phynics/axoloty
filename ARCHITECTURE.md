# Axoloty architecture

This document records the implemented architecture and its invariants. The
0.6 alignment ([epic #627](https://github.com/phynics/axoloty/issues/627)),
the 0.7 [runtime-registration](https://github.com/phynics/axoloty/issues/753)
and [transport-boundary](https://github.com/phynics/axoloty/issues/781)
epics, and the 0.8 firmware split
([epic #845](https://github.com/phynics/axoloty/issues/845)) are complete and
released. Their history is in [`docs/ROADMAP.md`](./docs/ROADMAP.md),
[`docs/releases/`](./docs/releases/), and git.

## Current implementation (0.8 checkpoint)

The released implementation consists of the root `Axoloty` host library, the
Foundation-free `AxolotyWire`, `AxolotyObjectModel`, and `AxolotyProtocol`
products, the separate `AxolotyMQTT` transport adapter, `AxolotyCoatyModels`
convenience product, and optional `AxolotyIoRouting`, `AxolotySensorThingsModel`,
and `AxolotySensorThings` products. The root package declares no executable
products: the `Tools` package owns the `axoloty-tool`/`ax` orchestration
harness, and the `Apps` package owns the `axoloty-inspect` inspector and
`axoloty-mcp` server, so neither `swift-sdk` nor a development-tool
dependency graph reaches a runtime consumer. The inherited class-object,
controller, manager, and SensorThings runtime hierarchy has been removed
from active production targets.

The host runtime target, `Axoloty`, contains the ``AxolotyRuntime``
lifecycle and the ``AxolotyRuntimeTransport`` port; it imports no MQTT or
SwiftNIO code. `AxolotyMQTT` is the sole MQTT/SwiftNIO adapter: it depends on
`Axoloty`, implements `AxolotyRuntimeTransport`, and is the only target a
consumer must add to obtain a working transport. `perform(_:)` takes a
`RuntimeTransportEffect` carrying a finished `RuntimeOutboundMessage` — route
synthesis (`CoatyRoute`) happens in the runtime, so an adapter needs no
Coaty-profile knowledge to address a publication. `ExternalIoRoute` is the
one typed external-IO route type; there is no MQTT-specific route type.
`AxolotyWire` supplies profile-neutral wire syntax, borrowed values, and
caller-owned parser workspaces; `AxolotyObjectModel` supplies bounded
semantic objects, schemas, predicates, and runtime-local registration;
`AxolotyProtocol` supplies the sealed Coaty/3 inventory, routing-key/frame
types, structured protocol errors, fixed-inline state, caller-owned action
sinks, route classification, the shared inbound/outbound processor, and
Coaty filter adaptation. Inspector and MCP consume the runtime through owned
event/request values and do not expose transport topics. Embedded firmware
composes ``AxolotyStaticRuntime`` and owns only transport, platform, and
main-loop concerns.

Runtime composition is split into a mutable ``RuntimeBuilder`` and immutable
``RuntimeDefinition``. The builder owns one value-semantic,
capacity-validating registration draft. ``finish()`` consumes the builder and
transfers that draft to the definition; the definition exposes no registration
or sealing API. First-party runtime modules are registered under stable
internal keys behind `package` access rather than a public SPI, and failed
multi-registration drafts discard handlers, streams, endpoints, module
entries, and correlation reservations together. Typed IO state is
concentrated behind the executor that owns it rather than spread across the
runtime surface, and SensorThings supports Thing-driven observation through
a bounded registry that performs exact Thing discovery and a
parent-filtered Sensor query.

[`docs/module-policy.yml`](./docs/module-policy.yml) declares every target's
role, platform class, and permitted/forbidden imports; `axoloty-tool
repository validate` checks every Swift source against it, so a new
cross-target dependency is a policy change rather than a silent one.

This section is the source of truth for what exists today. It must be updated whenever a gate changes the implemented package graph or removes a legacy path.

`AxolotyTooling` owns the release-evidence boundary: typed, exact-subject
envelopes rehash their declared artifacts, and a release is certified only by
an exact-SHA checkpoint that validates every required domain.

### Shared processor

[`Packages/AxolotyProtocol`](./Packages/AxolotyProtocol) owns the fixed-inline
processor, bounded action sink, handler table, subscription registry, and
binding-supplied route classifier. `AxolotyWire` contains only syntax, codecs,
validation, values, errors, and parser workspaces; no router or endpoint state
lives there. Host and Embedded Swift builds compile the same Foundation-free
sources, and release validation compares compiler-input receipts from both.

The fixture-backed trace contract and the host/static replay adapters under
`Tests/AxolotyTests/ProtocolTrace` are test-only. They translate fixtures into
real borrowed frames and typed local operations and drive the production
`ProtocolProcessor`, so they never form a second processor.

### Object model

`AxolotyObjectModel` owns bounded raw JSON, inline descriptors, semantic
envelopes, checked number views, presence, typed and manual schemas,
transactional edits, fixed runtime-local registration, and the bounded
Coaty-compatible predicate AST. Macro-generated schemas (`AxolotyObjectMacros`)
and manual conformances implement the same `ObjectSchema` contract; the macro
is not an Embedded runtime dependency. Unknown object types stay dynamic,
registration has no process-global side effects, and unknown fields and
number lexemes stay in the same bounded arena. `AxolotyProtocol` adapts Coaty
`objectFilter` values into the shared predicate implementation.
[`Spikes/BoundedObjectModelEvidence`](./Spikes/BoundedObjectModelEvidence)
maintains host and sanitizer evidence for the fixed-storage claims.

### Host and static runtimes

The `Axoloty` target has an explicit source list: runtime definition, host
runtime, the ``AxolotyRuntimeTransport`` port, and the error boundary. It
contains no MQTT or transport-client source. Its private actor executor owns
bounded ingress, dispatch, lifecycle, reconnect, cancellation, and
diagnostics, and all thirteen protocol families enter the shared
``ProtocolProcessor``. ``AxolotyStaticRuntime`` is the fixed synchronous
profile for Embedded Swift. Inspector and MCP use the same runtime contracts.

The required `g4-runtime-boundary`, `g4-runtime-package-boundary`, and
`g4-runtime-consumer-boundary` checks reject legacy runtime symbols, raw MQTT
APIs outside the adapter, parallel encoders, and implicit SwiftPM source
discovery. `AxolotySensorThings` supplies bounded Foundation-free schemas and
one atomic runtime-owned source and direct-observation module. Sources
validate Sensor-to-Thing parentage and deduplicate bounded Thing
advertisements; direct observation subscribes only to its configured Channel.

### Decision: transport-session mechanics stay in `ProtocolExecutor`

Issue [#664](https://github.com/phynics/axoloty/issues/664) investigated whether
the repeated transport mechanics in `ProtocolExecutor.start()` and
`reconnect()` should move into an internal transport-session module.

Decision: DENY

`ProtocolExecutor` remains the sole mutable lifecycle owner. Its state includes
the lifecycle transition and single-use guard, transport epoch, protocol
processor, ingress and outbound pumps, bounded offline work, handler
supervision, terminal-failure teardown, and diagnostics. Start, reconnect,
stop, close, and transport-failure paths make distinct lifecycle decisions
around those values; extracting the repeated calls would either create a
shallow helper or split ownership across actor boundaries.

The `AxolotyRuntimeTransport` protocol remains the useful failure-test seam.
Runtime tests inject failures at transport start, subscription installation,
and identity advertisement and verify terminal cleanup ordering. Epoch
supersession, cancellation, reconnect replay, and outbound shutdown draining
therefore remain explicit responsibilities of the actor rather than a hidden
session object.

## Capacity presets and payload bound

[ADR 0004](./docs/adr/0004-literal-inline-bounded-runtime-state.md) selects the
measured tiny/static/host capacity presets of 1/16/64 for runtime state. Those
measurements do not select object byte or field capacities: the object model
owns its own evidence, and the 2,048-byte/24-field convenience aliases are
wire-authority bounds rather than resource presets. Static runtime
specializations spell both dimensions (`StaticRuntime<capacity,
payloadCapacity>`); the payload dimension may be reduced below 2,048 bytes but
cannot exceed Axoloty's sealed wire maximum. This bounded-memory ceiling is an
intentional divergence from Coaty, which does not define a 2 KiB payload limit.

## Embedded consumer boundary

Firmware outside this repository consumes the portable packages through one
versioned contract, `docs/embedded-consumer-contract.json`, and the
`axoloty-tool embedded consumer prepare` command. The contract names the five
portable packages, their required compiler flags, the macro plugin inputs, and
the pinned `swift-json` identity. A consumer selects a checkout with
`AXOLOTY_SOURCE_DIR` and owns its scratch space; Axoloty's root `.build`, a
parent-directory layout, and the `Tests/` tree are outside the boundary. A
required, hardware-free gate compiles the portable packages for riscv32
Embedded Swift, expands the production macro, and links an external consumer
fixture.

Completed migration: concrete firmware composition, the ESP32-C6 toolchain, and
device qualification live in `phynics/axoloty-embedded` under epic #845.
Portable packages stay here and are never copied. This repository keeps only
the hardware-free Core Embedded Swift gate.

## Product boundary

Axoloty is a core runtime plus first-party development tools.

The core consists of a portable wire implementation, portable protocol processing and state, a host runtime profile, and a static runtime profile. The `AxolotyMQTT` adapter is the default and validated transport, not the definition of Axoloty networking: a consumer that never constructs a transport links no MQTT or SwiftNIO code. Inspector (`Apps`), MCP (`Apps`), and repository orchestration (`Tools`) are first-party tools that consume supported runtime interfaces from separate SwiftPM packages, not root-package products. SensorThings, Coaty convenience models, and automatic IO-routing policy are optional products rather than core protocol concerns.

## Runtime profiles

The host and static runtime profiles execute one portable protocol path. They
may choose different capabilities, capacities, transports, ownership and
delivery representations, scheduling adapters, and diagnostics, but they may
not differ in protocol semantics for overlapping inputs. The test adapters
provide replay evidence for this shared path; the host actor runtime owns
transport scheduling and application delivery.

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

The diagram below is the human-readable form. The enforced form is
[`docs/module-policy.yml`](./docs/module-policy.yml): one declaration per
target giving its role, platform class, allowed imports, and forbidden
imports. `axoloty-tool repository validate` checks every Swift source against
it, so a new dependency is a policy change rather than a silent one. Where the
two disagree, the policy is authoritative and this section is the defect.

```text
AxolotyWire
    ^
AxolotyObjectModel
    ^
AxolotyProtocol
    ^
AxolotyStaticRuntime

Axoloty host runtime ----> AxolotyProtocol
AxolotyMQTT (adapter) ----> Axoloty, AxolotyProtocol, AxolotyWire
Embedded firmware -------> AxolotyStaticRuntime
Optional products -------> supported Axoloty runtime and object APIs
Tools (axoloty-tool/ax), Apps (axoloty-inspect/axoloty-mcp) -> supported Axoloty runtime APIs
```

`AxolotyWire` owns wire syntax, codecs, validation, low-level object-envelope
decoding, borrowed and owned wire values, caller-owned parser workspaces, and
wire errors. It owns no semantic object schema, subscriber, endpoint,
association, correlation, handler, or processor state.

`AxolotyObjectModel` is the semantic layer above `AxolotyWire`.
It owns bounded typed/dynamic objects, presence, semantic envelopes, JSON
value/number views, predicates, and explicit sealed schema registries. It does
not own a transport, protocol processor, runtime
lifecycle, or global mutable registry. `AxolotyObjectMacros` is a build-time
schema-generation package and is not part of the portable runtime graph.

`AxolotyCoatyModels` is a separate first-party convenience product containing
the portable Coaty schema. It depends on `AxolotyObjectModel` and is compiled
from the same sources for host and Embedded Swift. IO contracts live in
`AxolotyProtocol` and SensorThings schemas in `AxolotySensorThingsModel`, not
in this convenience package.

`AxolotyProtocol` owns the closed built-in profile inventory, capabilities,
routing keys, portable frames, structured protocol errors, fixed-inline
request/association/subscriber state and subscription registry, protocol
capacities, route classifiers, handler tables, action sinks, and the shared
inbound/outbound processor. It
does not own a transport. It imports no MQTT/NIO, host object hierarchy,
logging, actor, or controller framework.

`AxolotyStaticRuntime` owns fixed composition, static delivery, bounded presets, and portable endpoint integration. It contains no protocol rule absent from `AxolotyProtocol`.

`AxolotyMQTT` owns the MQTT/SwiftNIO transport adapter: it implements `AxolotyRuntimeTransport` against `mqtt-nio` and is the only target in the graph that imports MQTT or SwiftNIO code. It depends on `Axoloty`, `AxolotyProtocol`, and `AxolotyWire`; nothing in those three imports it back, so a consumer that composes a runtime definition without constructing a transport never resolves or links MQTT/SwiftNIO.

## Architectural invariants

- `INV-001` **shared production processor (non-waivable):** host and static profiles compile the same production wire and protocol sources; no release may contain two production protocol processors.
- `INV-002` **sealed Coaty profile:** `coaty/3` is sealed as Coaty Core Profile 3; new first-party protocol primitives use separately versioned Axoloty profiles.
- `INV-003` **finite state:** portable protocol state is finite and saturation fails atomically with structured context.
- `INV-004` **borrowed-value scope:** borrowed values do not cross asynchronous or isolation boundaries.
- `INV-005` **typed external routes:** external non-Coaty routes exist only as typed Coaty IO external routes.
- `INV-006` **no general raw MQTT runtime API:** general raw MQTT application APIs are outside the target runtime.

Temporary violations require a narrow, expiring entry in [`docs/architecture-exceptions.yml`](./docs/architecture-exceptions.yml). The shared-production-processor invariant cannot be waived.

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
