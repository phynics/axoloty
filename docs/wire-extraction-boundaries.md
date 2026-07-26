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

Move the complete `Source/WireCodec/` directory into `AxolotyWire`:

- `BorrowedMessage.swift`, `ByteSlice.swift`, `TopicView.swift`,
  `TopicBuilder.swift`, `UUID16.swift`, and `WireBufferConfig.swift`;
- `WireReader.swift`, `WireWriter.swift`, `WireCodable.swift`,
  `WireDecodeError.swift`, and `WireDTOs.swift`;
- bounded routing primitives `MessageRouter.swift`,
  `EmbeddedMessageRouter.swift`, `StaticDispatchTable.swift`, and
  `StaticFamilyTable.swift`.

Keep host-specific source in `Axoloty`: MQTT/NIO transport, `Broadcast` and
other async stream infrastructure, host models, `CoatyUUID`, ErrorKit-facing
errors, runtime/container code, controllers, logging, and SensorThings.

## Dependency rule for AxolotyWire

The extracted target has no external runtime dependencies and must import none
of Foundation, NIO, MQTT, ErrorKit, logging, transport, host model, or actor
modules. Phase 2 must add automated import/dependency checks for this rule and
preserve the existing normalized Coaty wire compatibility suite across the
source move.
