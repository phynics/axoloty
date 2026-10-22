# Core 1.0 API audit

## Problem

The six Core products and the runtime transport interface are nearing their
first compatibility guarantee. ADR 0011 intentionally made the wire codec
format-neutral, and issues #1039–#1041 established the product boundary,
behavioral characterization, and diagnostics contract. The remaining risk was
that a few implementation or test entry points remained public, while the
transport adapter contract relied on no-op failure reporting and did not expose
optional carrier support.

## Usage (caller's view)

An MQTT application keeps the same composition shape:

```swift
let definition = try builder.finish()
let transport = try MQTTBinding(configuration: configuration)
let runtime = AxolotyRuntime(definition: definition, transport: transport)
try await runtime.start()
```

An adapter implementation declares its profile and optional features, installs
the receive and failure callbacks, applies one ordered effect at a time, then
releases callbacks on stop:

```swift
var capabilities: RuntimeTransportCapabilities { [.activityCounters] }
var wireProfile: WireProfile { .coaty3JSON }

func start(
    receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
    lastWill: RuntimeTransportLastWill?
) async throws(AxolotyError)
func setFailureHandler(
    _ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void
) async
func perform(_ effect: RuntimeTransportEffect) async throws(AxolotyError)
func stop() async
```

## Shape

The checked-in [symbol baseline](./core-1.0-public-symbols.json) contains each
reachable public declaration for the six products. Every entry is classified
`intentional-stable-api`. Implementation-only `@_spi(AxolotyRuntimeAdapter)`
imports from `AxolotyProtocol` remain internal adapter seams and are not part
of the normal-import API baseline. The baseline is tagged for version 1.0.0.
The [versioning policy](../versioning.md) limits the stability promise to those
six products; all other products remain experimental.

The audit retains `WireDecodable`, `WireEncodable`, and `WireCodec`. The codec
protocols are the format-neutral extension point selected by ADR 0011. Their
reader and writer arguments borrow payload storage only for the synchronous
call. `ByteSlice`, `TopicView`, borrowed wire events, and borrowed protocol
actions remain non-sendable where required; callers copy owned bytes before an
async or isolation boundary. `docs/API.md` describes these lifetime rules.

`ProtocolProcessor`, the protocol action sinks, and their borrowed and owned
action values remain stable. They are the low-level shared processing surface
owned by `AxolotyProtocol`; the host and static runtimes continue to compose
that same processor. `AxolotyStaticRuntime` remains the fixed synchronous
facade, not a second protocol implementation.

The transport contract now has one required startup operation, mandatory
post-start failure reporting, sequential `perform(_:)` calls, and an
idempotent `stop()`. Startup and effects report `AxolotyError`. Every runtime
publication and last will has a nonempty route within
`WireBufferConfig.maxTopicLength` and payload within
`WireBufferConfig.maxPayloadSize`. External-route transitions are similarly
bounded by the protocol route capacity. An adapter must reject external-route
effects when it does not support them. The runtime reports the transport's
optional features alongside protocol capabilities, wire profile, and finite
capacities in `RuntimeCapabilityInformation`.

The optional capability flags are `lastWill`, `recoveryNotifications`,
`activityCounters`, `profileInterest`, and `externalRouteSubscriptions`.
Failure reporting, profile selection, route classification, ordered effects,
and callback release at stop remain required parts of the interface. Defaults
for optional recovery notifications, counters, and namespace subscriptions are
explicit no-ops when their matching flag is absent.

## Synthesis decision

Two interface shapes were considered. Keeping every current overload and
documenting which no-op defaults are optional preserves adapter source, but it
leaves failure reporting silently optional and makes support difficult to
inspect. The chosen shape removes the duplicate start overload, requires the
failure callback, and reports the remaining optional features through one
fixed-width value. It keeps the current runtime injection point and the
format-neutral codec seam, so MQTT applications retain their composition path.

## Visibility decisions

| Declaration | Classification | Decision |
|---|---|---|
| Public declarations in the six-product baseline | Intentional stable API | Recorded individually in the JSON baseline. |
| `Axoloty.CoatyRoute.route` and `uuidString` | Reducible visibility | Package-only helpers; applications use typed operations and the selected transport. |
| `AxolotyRuntime.receive(_:)` | Reducible visibility | Package-only ingress seam; transports deliver frames through the registered callback. |
| `BorrowedExternalRouteTransition` constructors | Reducible visibility | Package-only constructors; the processor creates these borrowed transitions from validated routes. |
| `WireReader.isValidJSON(_:)` | Obsolete pre-1.0 API | Removed as a duplicate of `isValidJSONValue(_:)`. |
| `AxolotyRuntimeTransport.start(receive:)` | Obsolete pre-1.0 API | Removed as a duplicate of `start(receive:lastWill:)`. |

## Tradeoffs accepted

- We accept an adapter source update before 1.0 in exchange for startup,
  failure, and optional-capability behavior that is explicit at the seam.
- We accept a generated symbol inventory tied to the pinned Swift 6.4 toolchain
  in exchange for a repeatable declaration-level compatibility baseline.
- We accept that newly published transport capabilities are not automatically
  inferred from implementation methods; each adapter reports its own support.

## Alternatives considered

- Keep `start(receive:)` and the no-op failure callback as protocol requirements:
  this exposes a larger interface and lets an adapter silently lose runtime
  failure handling.
- Introduce a new runtime facade for transport adapters: this duplicates the
  existing `AxolotyRuntime` injection point and would change ordinary MQTT
  application composition without improving the adapter contract.

## Open questions and risks

Does a symbol baseline alone prove API compatibility? No. It records
declarations, not behavioral equivalence. Source and runtime behavior remain
covered by the characterization, transport-contract, wire compatibility, and
in-process MQTT tests.

## Next implementation step

Run `make api-baseline` after an API change and review its declaration diff
alongside compatibility tests and migration notes.
