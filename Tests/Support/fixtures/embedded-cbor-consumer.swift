// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

// CBOR-only consumer for the hardware-free Embedded Swift Core gate.
//
// The gate compiles this file together with the AxolotyWire portable sources
// and with no `_JSONCore` module in the include path. It writes and reads one
// `axoloty/1` CBOR map through the public format-neutral `WireCodec` surface,
// so a regression fails on behavior and not only on a missing symbol.
//
// The same source is linked for RISC-V Embedded Swift and executed on the
// host. It intentionally does not import `AxolotyWire` or `_JSONCore`: the
// gate compiles it into the portable module graph, exactly as the retired
// parser probe did.

@main
struct EmbeddedCBORConsumerProbe {
    static func main() {
        let capacity = 256
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { storage.deallocate() }

        let codec = WireCodec(profile: .axoloty1CBOR)
        var writer = codec.writer(buffer: storage, capacity: capacity)
        do throws(WireEncodeError) {
            try writer.beginObject()
            let name: StaticString = "sensor"
            try writer.writeStringField(
                "name",
                ByteSlice(bytes: name.utf8Start, length: name.utf8CodeUnitCount)
            )
            try writer.writeIntField("count", 7)
            try writer.writeBoolField("active", true)
            try writer.endObject()
        } catch {
            fatalError("CBOR-only encode failed")
        }

        let length = writer.position
        let reader = codec.reader(bytes: storage, length: length)
        do throws(WireDecodeError) {
            try reader.validate()
        } catch {
            fatalError("CBOR-only decode failed")
        }
        precondition(reader.readString("name")?.equals("sensor") == true, "name mismatch")
        precondition(reader.readInt("count") == 7, "count mismatch")
        precondition(reader.readBool("active") == true, "active mismatch")

        // Decode one `axoloty/1` event through the borrowed-message surface.
        // Issue #1027: `reader()`, `reader(workspace:)`, and `ownedEvent()`
        // must compile and run without `_JSONCore`, so a CBOR-only consumer
        // can decode an event and not only drive `WireCodec` directly.
        let topic: StaticString = "axoloty/1/ns/IOV/55555555-5555-4555-8555-555555555555"
        let eventCapacity = 64
        let eventStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: eventCapacity)
        defer { eventStorage.deallocate() }
        var eventWriter = codec.writer(buffer: eventStorage, capacity: eventCapacity)
        do throws(WireEncodeError) {
            try eventWriter.beginObject()
            try eventWriter.writeIntField("payload", 42)
            try eventWriter.endObject()
        } catch {
            fatalError("CBOR-only event encode failed")
        }

        let message = BorrowedMessage(
            topicBytes: topic.utf8Start,
            topicLength: topic.utf8CodeUnitCount,
            payloadBytes: eventStorage,
            payloadLength: eventWriter.position
        )
        precondition(message.profile == .axoloty1CBOR, "route profile mismatch")
        precondition(message.eventType == .ioValue, "event type mismatch")

        let routeReader = message.reader()
        precondition(routeReader.readInt("payload") == 42, "borrowed payload mismatch")

        var workspace = EmbeddedWireParserWorkspace()
        let workspaceReader = message.reader(workspace: &workspace)
        precondition(workspaceReader.readInt("payload") == 42, "workspace payload mismatch")

        do throws(WireDecodeError) {
            let owned = try message.ownedEvent()
            precondition(owned.profile == WireProfile.axoloty1CBOR, "owned profile mismatch")
            if case .ioValue(let value) = owned {
                precondition(value.profile == WireProfile.axoloty1CBOR, "owned field profile mismatch")
            } else {
                fatalError("owned event is not ioValue")
            }
        } catch {
            fatalError("CBOR-only ownedEvent failed")
        }
    }
}
