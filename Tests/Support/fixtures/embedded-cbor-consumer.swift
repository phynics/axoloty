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
    }
}
