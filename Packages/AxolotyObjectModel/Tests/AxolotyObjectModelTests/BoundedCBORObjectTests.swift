// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyObjectModel
import AxolotyWire
import Testing

struct BoundedCBORObjectTests {
    @Test("CBOR objects retain exact bytes and borrow raw values")
    func preservesEncodedObjectAndRawField() throws {
        let unknown: [UInt8] = [0xA2, 0x64, 0x6E, 0x61, 0x6D, 0x65, 0x63, 0x63, 0x61, 0x74,
                                0x66, 0x66, 0x75, 0x74, 0x75, 0x72, 0x65, 0x41, 0xFF]
        let object = try decode64x2(unknown)
        #expect(object.count == 2)

        var rawUnknown: [UInt8] = []
        #expect(object.withValue(for: "future") { rawUnknown = $0.ownedBytes() })
        #expect(rawUnknown == [0x41, 0xFF])

        var encoded: [UInt8] = []
        object.withEncodedBytes { encoded = $0.ownedBytes() }
        #expect(encoded == unknown)
        #expect(!object.withValue(for: "missing") { _ in })
    }

    @Test("CBOR object accepts exact byte and field capacity")
    func acceptsExactCapacity() throws {
        let object = try decode4x1([0xA1, 0x61, 0x61, 0x00])
        var raw: [UInt8] = []
        #expect(object.count == 1)
        #expect(object.withValue(for: "a") { raw = $0.ownedBytes() })
        #expect(raw == [0x00])
    }

    @Test("CBOR object rejects malformed maps and capacity overflow")
    func rejectsInvalidAndOversizedObjects() {
        do {
            let _ = try decode8x1([])
            Issue.record("empty input was accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x1([0xA1, 0x61, 0x61])
            Issue.record("truncated map was accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x1([0xA1, 0x61, 0x61, 0x18, 0x00])
            Issue.record("non-deterministic integer encoding was accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x1([0x81, 0x00])
            Issue.record("a non-map top-level value was accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x1([0xA1, 0x61, 0x61, 0x00, 0x00])
            Issue.record("trailing bytes after the map were accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x2([0xA2, 0x61, 0x61, 0x00, 0x61, 0x61, 0x01])
            Issue.record("a duplicate field key was accepted")
        } catch {
            #expect(error.reason == .invalidObject)
        }

        do {
            let _ = try decode8x1([0xA2, 0x61, 0x61, 0x00, 0x61, 0x62, 0x01])
            Issue.record("field overflow was accepted")
        } catch {
            #expect(error.reason == .capacityExceeded)
        }

        do {
            let _ = try decode3x1([0xA1, 0x61, 0x61, 0x00])
            Issue.record("byte overflow was accepted")
        } catch {
            #expect(error.reason == .capacityExceeded)
        }
    }

    private func decode64x2(_ bytes: [UInt8]) throws(ObjectError) -> BoundedCBORObject<64, 2> {
        try decode(bytes)
    }

    private func decode8x1(_ bytes: [UInt8]) throws(ObjectError) -> BoundedCBORObject<8, 1> {
        try decode(bytes)
    }

    private func decode4x1(_ bytes: [UInt8]) throws(ObjectError) -> BoundedCBORObject<4, 1> {
        try decode(bytes)
    }

    private func decode8x2(_ bytes: [UInt8]) throws(ObjectError) -> BoundedCBORObject<8, 2> {
        try decode(bytes)
    }

    private func decode3x1(_ bytes: [UInt8]) throws(ObjectError) -> BoundedCBORObject<3, 1> {
        try decode(bytes)
    }

    private func decode<let byteCapacity: Int, let fieldCapacity: Int>(
        _ bytes: [UInt8]
    ) throws(ObjectError) -> BoundedCBORObject<byteCapacity, fieldCapacity> {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, bytes.count))
        pointer.initialize(from: bytes, count: bytes.count)
        defer {
            pointer.deinitialize(count: bytes.count)
            pointer.deallocate()
        }
        return try BoundedCBORObject<byteCapacity, fieldCapacity>(decoding: ByteSlice(
            bytes: UnsafePointer(pointer),
            length: bytes.count
        ))
    }
}
