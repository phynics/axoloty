# AxolotyWire extraction boundaries

Phase 2 (#275) extracts the production-used, dependency-free wire core into
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

## Independent resolution (#293)

`AxolotyWire` is a separate SwiftPM package, not a target of the root
`Axoloty` package. SwiftPM resolves the full package dependency graph
before target/product selection, so a wire-only target in the root manifest
would still force consumers to resolve MQTTNIO, NIO, NIOSSL,
NIOTransportServices, Logging, ErrorKit, and IkigaJSON. The sub-package
declares no package dependencies, so a downstream consumer that depends only
on `AxolotyWire` resolves and fetches nothing from the host runtime graph.

The root `Axoloty` package consumes the sub-package via a local path
dependency (`.package(path: "Packages/AxolotyWire")`) and links
`.product(name: "AxolotyWire", package: "AxolotyWire")`. There is no parallel
codec implementation; both products refer to the same sources.

`Tests/Support/check-axoloty-wire-independent-resolution.sh` resolves the
`Packages/AxolotyWire/Fixtures/DownstreamConsumer` fixture — which depends
only on the local `AxolotyWire` package — and fails if any host runtime
dependency appears in the resolved graph.

The codec, borrowed-message, static-dispatch, and embedded-router regression
suites live in the root package's `AxolotyWireTests` target, which depends only
on `AxolotyWire`. Host differential and compatibility tests remain in
`AxolotyTests` because they deliberately compare the wire module with host
types and behavior.

### Distribution and migration

A downstream consumer that needs only the wire codec should depend on the
`AxolotyWire` package directly. While the package lives in this repository
as a sub-directory, a consumer can depend on it through a local path
dependency or a package registry that publishes the sub-package. Depending on
the root `Axoloty` package and selecting the `Axoloty` product will continue
to resolve the host runtime graph, which is expected for host consumers.
`import Axoloty` remains source-compatible because the shim re-exports
`AxolotyWire`.

## Dependency rule for AxolotyWire

AxolotyWire uses exact `phynics/swift-json` version `2.5.3`, published from
the upstream `ec81216` fork commit, with the
`IkigaJSONCore` product and disabled `FoundationSupport` trait. The fork's
swift-nio dependency may therefore appear during resolution, but NIO targets
must not be built or linked by the standalone wire fixture. The independent
resolution check treats this as an intentional resolution-only dependency.

The extracted target has no external runtime dependencies and must import none
of Foundation, NIO, MQTT, ErrorKit, logging, transport, host model, or actor
modules. Phase 2 must add automated import/dependency checks for this rule and
preserve the existing normalized Coaty wire compatibility suite across the
source move.
