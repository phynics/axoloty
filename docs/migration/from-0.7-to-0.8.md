# Migrate from 0.7 to 0.8

Axoloty 0.8 changes three public APIs. Applications that construct
`AxolotyRuntime` with the bundled `AxolotyMQTT` transport need no source
changes.

## Custom runtime transports

`AxolotyRuntimeTransport.setFailureHandler(_:)` now takes a handler for the
owned `RuntimeTransportFailure` value. Convert a foreign error before invoking
the handler:

```swift
// 0.7
func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) async

// 0.8
func setFailureHandler(_ handler: @escaping @Sendable (RuntimeTransportFailure) -> Void) async

// Reporting a failure
failureHandler?(RuntimeTransportFailure(code: .brokerUnavailable, detail: String(describing: error)))
```

`code` is a stable `AxolotyError.RuntimeErrorCode` for programmatic handling.
`detail` is a human-readable description.

The compiler does not flag a transport that keeps the 0.7 signature.
`AxolotyRuntimeTransport` provides a default `setFailureHandler(_:)`, so the
0.7 method becomes an unrelated overload and the runtime never installs its
handler. Search custom transports for `setFailureHandler` and update each
signature.

A transport may also implement `start(receive:lastWill:)` to install the
runtime's `RuntimeTransportLastWill`. A transport whose carrier has no
last-will feature can ignore it.

## Static runtime construction

`StaticRuntimeDefinition.init` and `StaticRuntime.init` throw
`ProtocolCapacityError` when a payload, object, or correlation capacity is
negative or exceeds its bound. In 0.7 they trapped. Add `try`:

```swift
// 0.7
var definition = StaticRuntimeDefinition<256>(registryID: registryID)

// 0.8
var definition = try StaticRuntimeDefinition<256>(registryID: registryID)
```

`StaticRuntimeDefinition` also accepts optional `maximumObjects` and
`maximumPendingCorrelations` arguments. When omitted, the consuming runtime's
capacity applies, which matches 0.7 behavior.

## Removed wire constants

| 0.7 | 0.8 |
|---|---|
| `WireBufferConfig.maxSubscribers` | No replacement. The constant was not enforced. |
| `WireBufferConfig.maxFamilyEntries` | No replacement. The constant was not enforced. |
| `WireBufferConfig.maxFamilySubscribers` | No replacement. The constant was not enforced. |

Protocol subscriber and family capacities are owned by `AxolotyProtocol`.
`WireBufferConfig.maxPayloadSize`, `maxTopicLength`, and `maxTopicLevels` are
unchanged.

## Behavior changes

- `AxolotyRuntime.state()` returns `.stopped` after a normal close. Code that
  treated `.failed` as the terminal state after `close()` should check for
  `.stopped`.
- The host runtime publishes its identity deadvertisement as an MQTT last will
  when the connection drops without a clean close.
