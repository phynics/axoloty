// Copyright (c) 2026 Atakan DULKER. Licensed under the MIT License.

import AxolotyWire
import Testing

/// Boundary tests for the current Foundation-free wire DTOs.
///
/// The former version compared these DTOs with a removed host Codable path.
/// The portable contract is now the wire reader/writer pair:
/// decode borrowed bytes, encode synchronously into caller-owned storage, and
/// decode the result again without allowing borrowed values to escape.
@Suite("Wire DTO boundaries")
struct WireDTOBoundaryTests {
    @Test("associate fields preserve optional and boundary values")
    func associateFieldsRoundTrip() throws {
        let input = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444","associatingRoute":"coaty/3/fuzz/IOV/33333333-3333-4333-8333-333333333333","isExternalRoute":true,"updateRate":250}"#
        let encoded = try roundTrip(input, as: AssociateWireData.self)

        try withReader(encoded) { reader in
            let value = try AssociateWireData(from: reader)
            #expect(value.ioSourceId == UUID16(parsing: "33333333-3333-4333-8333-333333333333"))
            #expect(value.ioActorId == UUID16(parsing: "44444444-4444-4444-8444-444444444444"))
            #expect(value.associatingRoute?.equals("coaty/3/fuzz/IOV/33333333-3333-4333-8333-333333333333") == true)
            #expect(value.isExternalRoute == true)
            #expect(value.updateRate == 250)
        }
    }

    @Test("associate disassociation omits optional fields")
    func associateDisassociationRoundTrip() throws {
        let input = #"{"ioSourceId":"33333333-3333-4333-8333-333333333333","ioActorId":"44444444-4444-4444-8444-444444444444"}"#
        let encoded = try roundTrip(input, as: AssociateWireData.self)

        try withReader(encoded) { reader in
            let value = try AssociateWireData(from: reader)
            #expect(value.associatingRoute == nil)
            #expect(value.isExternalRoute == nil)
            #expect(value.updateRate == nil)
        }
    }

    @Test("raw payload fields preserve their complete JSON value")
    func rawPayloadFieldsRoundTrip() throws {
        let inputs = [
            (#"{"payload":[0,1,2,255]}"#, "[0,1,2,255]"),
            (#"{"payload":42}"#, "42"),
            (#"{"payload":null}"#, "null"),
        ]

        for (input, expectedPayload) in inputs {
            let encoded = try roundTrip(input, as: IoValueWireData.self)
            try withReader(encoded) { reader in
                let value = try IoValueWireData(from: reader)
                #expect(value.payload.asString() == expectedPayload)
            }
        }
    }

    @Test("object and collection fields preserve raw wire shape")
    func objectFieldsRoundTrip() throws {
        let input = #"{"object":{"objectType":"example.Thing","objectId":"11111111-1111-4111-8111-111111111111"},"objects":[{"objectType":"example.Other"}],"privateData":{"enabled":true}}"#
        let encoded = try roundTrip(input, as: ChannelWireData.self)

        try withReader(encoded) { reader in
            let value = try ChannelWireData(from: reader)
            #expect(value.object?.asString() == #"{"objectType":"example.Thing","objectId":"11111111-1111-4111-8111-111111111111"}"#)
            #expect(value.objects?.asString() == #"[{"objectType":"example.Other"}]"#)
            #expect(value.privateData?.asString() == #"{"enabled":true}"#)
        }
    }

    @Test("required fields fail with structured portable errors")
    func requiredFieldsFail() {
        let missingSource = Array(#"{"ioActorId":"44444444-4444-4444-8444-444444444444"}"#.utf8)
        let malformedSource = Array(#"{"ioSourceId":"not-a-uuid","ioActorId":"44444444-4444-4444-8444-444444444444"}"#.utf8)

        for bytes in [missingSource, malformedSource] {
            do {
                try withReader(bytes) { reader in _ = try AssociateWireData(from: reader) }
                Issue.record("invalid associate payload was accepted")
            } catch let error as WireDecodeError {
                #expect(error.field != nil)
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }

    @Test("writer rejects output that exceeds the caller-owned buffer")
    func writerBoundsAreStructured() throws {
        let input = #"{"payload":{"value":[1,2,3]}}"#
        try withReader(Array(input.utf8)) { reader in
            let value = try IoValueWireData(from: reader)
            var output = [UInt8](repeating: 0, count: 8)
            do {
                try output.withUnsafeMutableBufferPointer { buffer throws in
                    var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
                    try value.encode(to: &writer)
                }
                Issue.record("undersized writer accepted an overflowing payload")
            } catch let error as WireEncodeError {
                #expect(error == .bufferOverflow)
            } catch {
                Issue.record("unexpected error type: \(error)")
            }
        }
    }
}

private func withReader<R>(_ bytes: [UInt8], _ body: (WireReader) throws -> R) throws -> R {
    if bytes.isEmpty {
        var sentinel: UInt8 = 0
        return try withUnsafePointer(to: &sentinel) { pointer in
            try body(WireReader(bytes: pointer, length: 0))
        }
    }
    return try bytes.withUnsafeBufferPointer { buffer in
        try body(WireReader(bytes: buffer.baseAddress!, length: buffer.count))
    }
}

private func roundTrip<T: WireDecodable & WireEncodable>(_ input: String, as _: T.Type) throws -> [UInt8] {
    let bytes = Array(input.utf8)
    return try withReader(bytes) { reader in
        let value = try T(from: reader)
        var output = [UInt8](repeating: 0, count: 512)
        let count = try output.withUnsafeMutableBufferPointer { buffer throws -> Int in
            var writer = WireWriter(buffer: buffer.baseAddress!, capacity: buffer.count)
            try value.encode(to: &writer)
            return writer.position
        }
        return Array(output[..<count])
    }
}
