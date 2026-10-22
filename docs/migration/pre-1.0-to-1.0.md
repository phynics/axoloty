# Migrate pre-1.0 code to Core 1.0

Core 1.0 freezes the public surface of `Axoloty`, `AxolotyWire`,
`AxolotyProtocol`, `AxolotyObjectModel`, `AxolotyStaticRuntime`, and
`AxolotyMQTT`. This note lists the pre-1.0 source changes made during the API
audit. It does not describe a released migration; the current release version
remains in `VERSION`.

## Transport adapter changes

Implement one startup operation that accepts the optional last will:

```swift
func start(
    receive: @escaping @Sendable (RuntimeInboundFrame) -> Void,
    lastWill: RuntimeTransportLastWill?
) async throws(AxolotyError)
```

Remove the old `start(receive:)` conformance. Code that starts a binding
directly now passes `lastWill: nil`; normal applications continue to call
`AxolotyRuntime.start()`. Report supported optional adapter
features through `capabilities`, and implement `setFailureHandler` rather than
relying on a default no-op. Convert carrier errors to `AxolotyError` for
startup, effect application, and profile-interest operations. Report every
post-start failure through the owned `RuntimeTransportFailure` callback.

`RuntimeTransportCapabilities` reports last-will support, recovery
notifications, activity counters, profile-interest subscriptions, and exact
external-route subscriptions. Do not set a flag unless the adapter implements
that feature. An adapter without external-route subscriptions must reject an
external-route effect as unsupported. The runtime exposes the selected flags
in `RuntimeCapabilityInformation`.

`RuntimeOutboundMessage` and `RuntimeTransportLastWill` initializers now throw
`AxolotyError` for an empty route, a route longer than
`WireBufferConfig.maxTopicLength`, or a payload longer than
`WireBufferConfig.maxPayloadSize`. `OwnedExternalRouteTransition` construction
throws `ProtocolError` when the route is empty or too long. Use `try` at these
construction sites.

## Removed implementation and duplicate APIs

- Remove application calls to `AxolotyRuntime.receive(_:)`. The runtime receives
  transport frames through `AxolotyRuntimeTransport.start(receive:lastWill:)`.
- Replace `WireReader.isValidJSON(_:)` with `WireReader.isValidJSONValue(_:)`.
- Do not construct `BorrowedExternalRouteTransition` directly. Its internal
  constructors are reserved for the protocol processor's validated route
  snapshots.
- Do not call `CoatyRoute` directly. Publish typed runtime operations and let
  the runtime resolve profile routes.

## Preserved MQTT application composition

Applications that build a `RuntimeDefinition`, create an `MQTTBinding`, and
pass it to `AxolotyRuntime` do not need a new composition facade. MQTT continues
to carry `coaty/3`, apply ordered publications and exact external routes, copy
inbound frames, and install an optional broker last will. The MQTT adapter
contract and in-process broker tests characterize this behavior.
