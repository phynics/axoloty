---
status: accepted
---

# Codify the approved product and ownership contracts

This ADR records the approved Q1–Q86 direction summarized in the historical
review at [#978](https://github.com/phynics/axoloty/issues/978) and tracked by
[#1039](https://github.com/phynics/axoloty/issues/1039). Axoloty is a bounded,
Embedded-Swift-capable distributed object runtime with Coaty wire semantics.
`coaty/3` JSON is the compatibility profile, and `axoloty/1` CBOR is the native
profile.

## Context

Axoloty is approaching the Core 1.0 API freeze. Firmware and device
qualification moved to `phynics/axoloty-embedded`, host Zenoh shipped as
experimental, and `axoloty/1` CBOR became the native wire profile. Product
scope, ownership, and exclusions were restated across the architecture,
roadmap, and versioning documents with different wording and some stale
references. Without one governing record, the 1.0 audit and release gates
cannot tell which products and behaviors are in scope.

## Decision

### Stable products

The Core 1.0 stability contract covers exactly these six library products:

| Product | Owns |
|---|---|
| `Axoloty` | Host runtime lifecycle, scheduling, transport ownership, bounded ingress, and diagnostics. |
| `AxolotyWire` | Profile-neutral wire syntax, route envelopes, codecs, validation, and wire values. |
| `AxolotyProtocol` | Sealed profile inventory, routing keys, frame boundaries, bounded state, and the shared processor. |
| `AxolotyObjectModel` | Bounded semantic objects, schemas, presence, number and JSON views, and predicates. |
| `AxolotyStaticRuntime` | Fixed synchronous composition around one shared processor. |
| `AxolotyMQTT` | The MQTT transport adapter binding. |

This table is authoritative for product ownership.
[`docs/versioning.md`](../versioning.md) records versioning and deprecation
policy for the same set.

Every other product and tool remains experimental and outside the Core 1.0 API
stability promise. This includes the Zenoh products, Coaty convenience models,
IO routing, SensorThings products, macro-generated schema support
(`AxolotyObjectMacros`), the `Tools` harness, and the products in the sibling
`phynics/axoloty-debug` package. Zenoh promotion is a separate decision.
Device peer-mode qualification is deferred beyond embedded v1.

### Repository ownership

The repositories have separate owners:

| Repository | Ownership |
|---|---|
| [`phynics/axoloty`](https://github.com/phynics/axoloty) | Portable Core, wire and protocol implementations, the host runtime, MQTT, and experimental host Zenoh bindings. |
| [`phynics/axoloty-embedded`](https://github.com/phynics/axoloty-embedded) | Firmware products, platform and C-ABI integration, hardware support, and device qualification. |
| [`phynics/axoloty-debug`](https://github.com/phynics/axoloty-debug) | Operator tooling, the `serve` CLI, object inspection, MCP, and process supervision. |

### Coaty inheritance

Axoloty inherits Coaty Core Profile 3 wire semantics: object envelopes, event
families, and filters. It does not inherit the Coaty controller and manager
runtime, the global class registry, or controller restoration; ADR 0003
replaces that architecture. Coaty convenience models remain experimental.

### Wire profiles and object authority

`coaty/3` is the sealed JSON compatibility profile for Coaty interoperability.
In Core v1, MQTT carries `coaty/3`. `axoloty/1` is the separately versioned
CBOR profile for Axoloty-native communication. Zenoh carries `axoloty/1` only.
Each profile defines a separate wire domain. Axoloty does not automatically
translate or forward messages between profiles or transports.

The application owns durable object data and conflict resolution.
`AxolotyObjectModel` represents bounded object values and schema semantics; it
is not a persistent or replicated store. `AxolotyProtocol` interprets protocol
operations and owns bounded protocol state. It does not establish a globally
authoritative object view. Applications own persistence and business
authorization.

`AxolotyWire` owns wire syntax and codecs. `AxolotyObjectModel` owns semantic
object representation. `AxolotyProtocol` owns protocol meaning and state
transitions. Runtime profiles compose those layers without adding protocol
rules.

### Host and static runtime semantics

Host and static profiles use the same production wire and protocol path. For
overlapping inputs, they have the same protocol semantics. They may differ in
capacity, transport, ownership, delivery representation, scheduling, and
diagnostics.

The host runtime owns lifecycle, transport scheduling, bounded ingress, and
asynchronous application delivery. A transport adapter owns carrier mechanics
and implements the runtime interface; it does not define protocol meaning or
create a bridge to another wire domain. `AxolotyStaticRuntime` provides fixed
synchronous composition. Embedded firmware owns platform, hardware, and
main-loop integration.

### Explicit non-goals

The Core contract does not include:

- a replicated object store;
- Core consensus or Raft;
- automatic replay of accepted request commands after reconnect;
- controller restoration;
- a Core authentication or authorization contract;
- an automatic bridge between wire domains or transports;
- BLE Mesh or other BLE transports;
- device peer-mode qualification before embedded v1.

Reconnect may replay one-way publications, but it never replays accepted
request commands or reopens their correlations.

## Relationship to ADRs 0001–0011

This ADR codifies product scope and ownership. It does not rewrite earlier
accepted decisions. The existing ADRs remain in force except where an earlier
ADR already records a scoped supersession:

| ADR | Relationship |
|---|---|
| [0001](./0001-shared-protocol-critical-path.md) | Remains in force: host and static profiles share the production protocol path. |
| [0002](./0002-seal-coaty-core-profile-3.md) | Remains in force: `coaty/3` stays sealed and Axoloty extensions use separate profiles. |
| [0003](./0003-replace-inherited-runtime-and-object-architecture.md) | Remains in force: the inherited controller and global-registry architecture is replaced. |
| [0004](./0004-literal-inline-bounded-runtime-state.md) | Remains in force: portable runtime state is fixed-capacity and inline. |
| [0005](./0005-portable-object-model-boundary.md) | Remains in force: semantic objects belong to `AxolotyObjectModel`, above `AxolotyWire`. |
| [0006](./0006-zenoh-host-dependency-packaging.md) | The packaging decision remains in force. ADR 0010 supersedes its host-matrix claim. |
| [0007](./0007-zenoh-adapter-package-boundary.md) | Remains in force: Zenoh stays in its separate SwiftPM package. |
| [0008](./0008-axoloty-1-cbor-extension-profile.md) | The profile definition remains in force. ADR 0009 supersedes its Zenoh profile-selection rules. |
| [0009](./0009-zenoh-carries-only-axoloty-1.md) | Remains in force: Zenoh carries only `axoloty/1`; MQTT carries `coaty/3` in v1. |
| [0010](./0010-zenoh-supported-host-matrix.md) | Remains in force: it supersedes only ADR 0006's host-matrix claim. |
| [0011](./0011-codec-format-seam.md) | Remains in force: format selection stays behind the profile-neutral wire facade. |

## Consequences

- The [#1000](https://github.com/phynics/axoloty/issues/1000) API audit freezes
  exactly the six products above. Promoting another product into the stable set
  requires a superseding ADR.
- Experimental packages may change or be removed in any release. They remain
  usable, including through the embedded consumer contract, but carry no API
  stability promise.
- `coaty/3` and `axoloty/1` remain separate wire domains. A deployment that
  needs both runs both bindings in the application.
- Behavioral characterization was delivered in
  [#1047](https://github.com/phynics/axoloty/issues/1047), and typed
  diagnostics in [#1048](https://github.com/phynics/axoloty/issues/1048).
  Remaining 1.0 acceptance work is tracked by
  [#1043](https://github.com/phynics/axoloty/issues/1043).
