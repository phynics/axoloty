# AxolotyWire extraction boundaries

Phase 2 (#275) extracts the production-used, Foundation-free wire core into
the `AxolotyWire` library product. This document records the Phase 1 boundary;

## Ownership boundary

Embedded routing is synchronous. `BorrowedMessage`, `ByteSlice`, `TopicView`,
`WireReader`, and `WireWriter` borrow receive-buffer storage and must not cross
an `await`, task, actor boundary, or escaping closure.

Host ingress is the ownership boundary. `MQTTNIOClient.handlePublish` copies
mqtt-nio's `ByteBuffer` into `[UInt8]`, materializes topic metadata into
`String` values while the `withUTF8` borrow is in scope, and yields async work
that captures only owned `Sendable` values: `RawMQTTMessage`,
`IoValueEventSnapshot`, and `ParsedMQTTMessage`.

## Phase 2 source move

The complete wire core lives in the standalone `AxolotyWire` package at
`Packages/AxolotyWire/`:

- `Sources/AxolotyWire/`: `BorrowedMessage.swift`, `ByteSlice.swift`,
  `TopicView.swift`, `TopicBuilder.swift`, `UUID16.swift`,
  `WireBufferConfig.swift`, `WireReader.swift`, `WireWriter.swift`,
  `WireCodable.swift`, `WireDecodeError.swift`, `WireDTOs.swift`,
  `MessageRouter.swift`, `EmbeddedMessageRouter.swift`,
  `StaticDispatchTable.swift`, and `StaticFamilyTable.swift`.

Keep host-specific source in the root `Axoloty` target under `Source/`:
MQTT/NIO transport, `Broadcast` and other async stream infrastructure, host
models, `CoatyUUID`, ErrorKit-facing errors, runtime/container code,
controllers, logging, and SensorThings. `Source/Common/WireImportShim.swift`
re-exports `AxolotyWire` so existing `import Axoloty` clients keep compiling.

## Distribution boundaries (#459)

The root `Axoloty` package exposes an `AxolotyWire` product whose target points
at the shared `Packages/AxolotyWire/Sources/AxolotyWire` sources. Selecting that
product narrows target compilation and linking, but it does not narrow SwiftPM
package resolution: SwiftPM resolves the root manifest's host graph before
target/product selection. A root-package wire consumer therefore resolves
MQTTNIO, SwiftNIO, NIOSSL, NIOTransportServices, Logging, ErrorKit, and the
other root dependencies even when it builds only `AxolotyWire`.

`Packages/AxolotyWire/Package.swift` is the standalone package boundary. It
declares only the exact `phynics/swift-json` package and its `IkigaJSONCore`
product. That dependency can expose SwiftNIO as resolution-only transitive
metadata, but the standalone wire consumer must not build or link NIO targets
or any host runtime package. Both root and standalone products refer to the
same source files; there is no parallel codec implementation.

`Tests/Support/check-axoloty-wire-distribution.sh` validates both supported
consumer topologies. Its root consumer asserts the full root resolution graph,
builds only the wire target, and executes the linked binary. Its standalone
consumer uses the canonical `Packages/AxolotyWire/Fixtures/DownstreamConsumer`
fixture, asserts independent resolution and no host target compilation, and
executes the linked binary. The lower-level
`check-axoloty-wire-independent-resolution.sh` gate remains the standalone
resolution/build check.

The codec, borrowed-message, static-dispatch, and embedded-router regression
suites live in the root package's `AxolotyWireTests` target, which depends only
on `AxolotyWire`. Host differential and compatibility tests remain in
`AxolotyTests` because they deliberately compare the wire module with host
types and behavior.

### Distribution and migration

A downstream consumer that needs independent wire-only package resolution
should depend directly on the standalone `AxolotyWire` package, using
`Packages/AxolotyWire` as the canonical package boundary. A consumer that
already depends on the root package may instead select its `AxolotyWire`
product for source and target-level wire isolation, while accepting the root
package's full resolution graph. `import Axoloty` remains source-compatible
because the shim re-exports `AxolotyWire`.

## Dependency rule for AxolotyWire

AxolotyWire uses exact `phynics/swift-json` version `2.5.3`, published from
the upstream `ec81216` fork commit, with the
`IkigaJSONCore` product and disabled `FoundationSupport` trait. The fork's
swift-nio dependency may therefore appear during resolution, but NIO targets
must not be built or linked by the standalone wire fixture. The independent
resolution check treats this as an intentional resolution-only dependency.

The extracted target has no host runtime dependencies and must import none of
Foundation, NIO, MQTT, ErrorKit, logging, transport, host model, or actor
modules. Its parser dependency is intentional and is not described as
dependency-free. The distribution checks preserve this distinction while the
normalized Coaty wire compatibility suite continues to cover the shared
source.
