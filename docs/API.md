# Axoloty 0.5.1 API documentation

Axoloty 0.5.1 is the published package version. The repository is preparing
the 0.6 runtime at the G5 checkpoint. The APIs below describe the current
runtime cutover; SensorThings is available as an optional product.

## Package boundaries

| Package | Responsibility |
|---|---|
| `AxolotyWire` | Foundation-free topics, codecs, envelopes, validation, and borrowed/owned wire values. |
| `AxolotyObjectModel` | Bounded object envelopes, dynamic objects, predicates, and sealed schema registries. |
| `AxolotyProtocol` | The shared fixed-inline processor, correlations, association state, route classification, and normalized actions. |
| `Axoloty` | The host lifecycle, bounded ingress, scheduling, handler supervision, and `MQTTBinding`. |
| `AxolotyStaticRuntime` | Synchronous fixed-storage composition for Embedded Swift. |
| `AxolotySensorThings` | Optional bounded SensorThings schemas and runtime-owned source/observer workflows. |

Every host and static protocol transition enters `AxolotyProtocol`. The host
runtime owns transport and concurrency policy; the static runtime owns only a
caller-supplied clock, transport loop, and fixed callbacks.

## Host runtime

Configure a runtime before starting it, then seal the definition:

```swift
let identity = try RuntimeIdentity(id: agentID, name: "inspector")
var definition = try RuntimeDefinition(
    namespace: "building-a",
    sourceID: agentID,
    identity: identity,
    capacities: try RuntimeCapacities()
)
let resolves = try definition.registerEvents(
    matching: .family(.resolve),
    buffering: .dropOldest(capacity: 64)
)
let sealed = try definition.seal()
let runtime = AxolotyRuntime(
    definition: sealed,
    transport: try MQTTBinding(configuration: configuration)
)
try await runtime.start()
```

`RuntimeDefinition` is mutable only during configuration. A sealed definition
contains the bounded identity, capacities, event registrations, and responder
registrations used by one `AxolotyRuntime` instance. A runtime is single-use:
`start()` transitions it to `.running`, `stop()` drains bounded work and leaves
it `.stopped`, and a new instance is required after shutdown.

The public lifecycle states are `initialized`, `starting`, `running`,
`reconnecting`, `stopping`, `stopped`, and `failed`. `run()` owns a normal
long-lived lifecycle loop; `start()` and `stop()` are useful for callers that
own their surrounding task.

## Operations and events

The runtime exposes the thirteen closed Coaty Core families through typed
values:

- one-way operations: `advertise`, `deadvertise`, `channel`, `associate`, and
  `ioValue`;
- requests: `discover`, `query`, `update`, and `call`;
- responses: `resolve`, `retrieve`, `complete`, and `returnEvent`.

Submit these values through the matching runtime entry point: `publish(_:)`
for one-way operations, `request(_:)` for requests, and `respond(_:)` for
responses. The runtime supplies its configured source identity when it
translates each value to the shared protocol operation. Associate accepts an
context name through `.associateInContext(contextName:payload:)`; use the
existing `.associate(_:)` spelling when no context is required.

`RuntimeEventValue` contains an owned payload and a `RuntimeEventContext` with
source identity, optional correlation, namespace, route classification,
monotonic receipt time, and provenance. It never exposes a raw transport topic
or a transport-owned buffer.

Discover and Query are multi-response correlations. Update and Call are unary
correlations. A request with a finite `timeoutMS` expires at the caller's
monotonic deadline; a Discover request with `timeoutMS: nil` remains active
until a response, explicit cancellation, reconnect, or shutdown. Late,
duplicate, mismatched, and expired responses are rejected without mutation.

Application event streams are registered before startup and use one bounded
`RuntimeBufferingPolicy`: `fail`, `dropOldest`, `dropNewest`, or
`coalesceLatest`. Transport ingress is never lossy. If its bounded queue is
full, the runtime reports a structured overload failure rather than silently
discarding protocol input.

## Static runtime

`AxolotyStaticRuntime.StaticRuntime<capacity, payloadCapacity>` composes one
`ProtocolProcessor`, one `ProtocolSubscriptionRegistry`, and one inline action
sink. `receive`, `send`, `expire`, `cancel`, and `drain` are synchronous. The
caller drains actions before borrowed topic or payload bytes leave scope.

`payloadCapacity` is a compile-time value between 0 and the sealed 512-byte
Coaty Core 3 payload limit. The established presets use 512 bytes; smaller
deployments can select, for example, `StaticRuntime<16, 128>` to reduce inline
storage. The former `StaticRuntime<capacity>` spelling migrates to
`StaticRuntime<capacity, 512>`, and `StaticRuntimeDefinition` is spelled
`StaticRuntimeDefinition<512>`.

The accepted storage profiles are `tiny = 1`, `esp32C6Static = 16`, and
`hostDefault = 64`. Static handlers are noncapturing thin functions with
caller-owned numeric context handles; no task, actor, Foundation value, or
growable collection is part of the static runtime.

## Borrowed-value lifetime rules

Wire views such as `ByteSlice` and `TopicView` borrow externally owned bytes for
synchronous work. Never retain them, pass them across an actor or task, or
store them in an asynchronous stream. Copy the required bytes into an owned
value before any suspension point. Validate untrusted bytes at the wire
boundary before reading fields.

`BorrowedProtocolAction` is valid only during the synchronous handler or sink
call that receives it. Use its owned conversion when data must outlive that
call.

## Errors and diagnostics

Public runtime boundaries wrap foreign failures in `AxolotyError`. Stable
categories include invalid arguments, invalid configuration, decoding
failures, runtime state failures, transport failures, and caught underlying
errors. Runtime receipts preserve protocol categories such as malformed frame,
malformed payload, capacity exceeded, duplicate, deadline expired, stale
correlation, and unsupported capability.

`RuntimeDiagnostics` provides bounded counters for ingress saturation, stream
drops, handler saturation, reconnects, expired requests, malformed frames, and
transport failures. Diagnostic streams contain owned values and can be
consumed independently of application event streams.

## Wire and route authority

All family payloads are encoded and decoded through `AxolotyWire` and the
Foundation-free protocol codecs. The binding supplies route classification;
there is no profile-wide route grammar. Canonical outbound Associate omits the
optional external-route flag. Inbound omission is accepted, an explicit flag
must agree with the binding classification, and unrelated routes are ignored.
The exact CoatyJS external fixture is
`external/wire-compat-v1/io-external-1`.
